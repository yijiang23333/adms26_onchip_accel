#!/bin/bash

# ENFORCE ROOT EXECUTION
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run with sudo."
  exit 1
fi

QAT_TEST="/scratch/yijiang/QATzip/test/qatzip-test"
QZIP_BIN=$(command -v qzip)
TEST_FILE="/scratch/yijiang/tpch-dbgen/tpch-sf10/lineitem_500M.tbl"
RESULTS_CSV="qat_single_device_saturation.csv"

export TARGET_QAT_DEVICE="0000:01:00.0"

# Verify binaries and test file exist
if [ ! -f "$QAT_TEST" ]; then echo "Error: $QAT_TEST not found."; exit 1; fi
if [ -z "$QZIP_BIN" ]; then echo "Error: qzip binary not found in PATH."; exit 1; fi
if [ ! -f "$TEST_FILE" ]; then echo "Error: $TEST_FILE not found."; exit 1; fi

# Get exact raw file size in bytes
RAW_FILE_SIZE=$(stat -c%s "$TEST_FILE")

# Process scale arrays matching your test environment
PROCESSES=(1 2 4 8 16 32 64 96)
#BLOCK_SIZES=(4096 8192 16384 32768 65536 131072 262144 524288 1048576 2097152) 4K to 2M
BLOCK_SIZE=2097152

echo "Algorithm,Processes,Total_Comp_MBps,Total_Decomp_MBps,Compression_Ratio" > $RESULTS_CSV

run_multiprocess_sweep() {
    local alg_name=$1
    echo "--- Running Single-Device Sweep ($TARGET_QAT_DEVICE) for $alg_name ---"

    local base_flags="-b $BLOCK_SIZE -B 0 -r 32 -l 10"
    local qzip_setup_flags=""

    if [ "$alg_name" == "lz4" ]; then
        base_flags="-A lz4 -O lz4 $base_flags"
        qzip_setup_flags="-A lz4 -O lz4"
    elif [ "$alg_name" == "deflate_dynamic" ]; then
        base_flags="-A deflate -O gzipext -T dynamic $base_flags"
        qzip_setup_flags="-A deflate -O gzipext -H dynamic"
    elif [ "$alg_name" == "deflate_static" ]; then
        base_flags="-A deflate -O gzipext -T static $base_flags"
        qzip_setup_flags="-A deflate -O gzipext -H static"
    fi

    local comp_payload="/tmp/qat_payload_${alg_name}.comp"
    
    # =========================================================
    # SETUP: Pre-compress the raw file matching the block size
    # =========================================================
    export QAT_PCI_BDFS="$TARGET_QAT_DEVICE"
    echo "  [Setup] Generating compressed payload for $alg_name..."
    
    rm -f /tmp/qat_setup_temp*
    cp "$TEST_FILE" "/tmp/qat_setup_temp.tbl"
    
    $QZIP_BIN $qzip_setup_flags -b $BLOCK_SIZE "/tmp/qat_setup_temp.tbl" > /dev/null 2>&1

    if [ "$alg_name" == "lz4" ]; then
        mv "/tmp/qat_setup_temp.tbl.lz4" "$comp_payload" 2>/dev/null
    else
        mv "/tmp/qat_setup_temp.tbl.gz" "$comp_payload" 2>/dev/null
    fi
    rm -f "/tmp/qat_setup_temp.tbl"

    if [ ! -s "$comp_payload" ]; then
        echo "  [Error] Failed to generate compressed payload. File is empty."
        return
    fi

    # FIXED: Calculate the exact compression ratio directly from the physical payload size
    local comp_file_size=$(stat -c%s "$comp_payload")
    local comp_ratio=$(awk "BEGIN {printf \"%.2f\", ($RAW_FILE_SIZE / $comp_file_size)}")

    # =========================================================
    # BENCHMARK LOOP
    # =========================================================
    for p in "${PROCESSES[@]}"; do
        echo "Testing with $p Concurrent Process(es)..."
        rm -f /tmp/qat_run_*.log

        # 1. Spawn Compression processes
        for i in $(seq 1 $p); do
            numactl --cpunodebind=0 --membind=0 $QAT_TEST -m 4 -i "$TEST_FILE" -t 1 $base_flags -D comp > "/tmp/qat_run_comp_${i}.log" 2>&1 &
        done
        wait

        local total_c_mbps=0
        for i in $(seq 1 $p); do
            local log="/tmp/qat_run_comp_${i}.log"
            if grep -q "srv=COMP" "$log" 2>/dev/null; then
                local line_c=$(grep "srv=COMP" "$log" | head -n 1)
                local val_c=$(echo "$line_c" | grep -ioP '[0-9]+(\.[0-9]+)?(?=\s*[MG]BPS)')
                local unit_c=$(echo "$line_c" | grep -ioP '[MG]BPS' | tr '[:lower:]' '[:upper:]')
                val_c=${val_c:-0}

                if [[ "$unit_c" == "GBPS" ]]; then
                    val_c=$(awk "BEGIN {print ($val_c * 1000) / 8}")
                elif [[ "$unit_c" == "MBPS" ]]; then
                    val_c=$(awk "BEGIN {print $val_c / 8}")
                fi
                total_c_mbps=$(awk "BEGIN {print $total_c_mbps + $val_c}")
            fi
        done

        # 2. Spawn Decompression processes
        for i in $(seq 1 $p); do
            numactl --cpunodebind=0 --membind=0 $QAT_TEST -m 4 -i "$comp_payload" -t 1 $base_flags -D decomp > "/tmp/qat_run_decomp_${i}.log" 2>&1 &
        done
        wait

        local total_d_mbps=0
        for i in $(seq 1 $p); do
            local log="/tmp/qat_run_decomp_${i}.log"
            if grep -q "srv=DECOMP" "$log" 2>/dev/null; then
                local line_d=$(grep "srv=DECOMP" "$log" | head -n 1)
                local val_d=$(echo "$line_d" | grep -ioP '[0-9]+(\.[0-9]+)?(?=\s*[MG]BPS)')
                local unit_d=$(echo "$line_d" | grep -ioP '[MG]BPS' | tr '[:lower:]' '[:upper:]')
                val_d=${val_d:-0}

                if [[ "$unit_d" == "GBPS" ]]; then
                    val_d=$(awk "BEGIN {print ($val_d * 1000) / 8}")
                elif [[ "$unit_d" == "MBPS" ]]; then
                    val_d=$(awk "BEGIN {print $val_d / 8}")
                fi
                total_d_mbps=$(awk "BEGIN {print $total_d_mbps + $val_d}")
            fi
        done

        # Log results
        if (( $(echo "$total_c_mbps == 0" | bc -l) )); then
            echo "$alg_name,$p,ERR,ERR,ERR" >> $RESULTS_CSV
            echo "  [FAIL] Hardware queue rejected requests or parsing failed."
        else
            echo "$alg_name,$p,$total_c_mbps,$total_d_mbps,$comp_ratio" >> $RESULTS_CSV
            printf "  Total Result -> Comp: %7.2f MB/s | Decomp: %7.2f MB/s | Ratio: %s\n" "$total_c_mbps" "$total_d_mbps" "$comp_ratio"
        fi
    done
    
    rm -f "$comp_payload"
}

# Run the sweeps
run_multiprocess_sweep "lz4"
echo "------------------------------------------------"
run_multiprocess_sweep "deflate_dynamic"
echo "------------------------------------------------"
run_multiprocess_sweep "deflate_static"
echo "------------------------------------------------"

echo "Saturation test complete. Results written to $RESULTS_CSV"