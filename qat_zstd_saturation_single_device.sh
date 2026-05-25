#!/bin/bash

# ENFORCE ROOT EXECUTION
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run with sudo."
  exit 1
fi

ZSTD_BENCH="/scratch/yijiang/QAT-ZSTD-Plugin/test/benchmark"
TEST_FILE="/scratch/yijiang/tpch-dbgen/tpch-sf10/lineitem.tbl"
RESULTS_CSV="qat_zstd_saturation_results.csv"

# Verify benchmark tool exists
if [ ! -f "$ZSTD_BENCH" ]; then
  echo "Error: $ZSTD_BENCH not found. Please run this script from your QAT-ZSTD-Plugin root directory."
  exit 1
fi

# Verify the manually generated test file exists
if [ ! -f "$TEST_FILE" ]; then
  echo "Error: $TEST_FILE not found."
  exit 1
fi

THREADS_ARRAY=(1 2 4 8 16)
CHUNK_SIZE="4K"
COMPRESSION_LEVEL=1

echo "Mode,Threads,Comp_Throughput_MBps,Decomp_Throughput_MBps,Compression_Ratio" > $RESULTS_CSV

run_zstd_sweep() {
    local use_qat=$1 # 0 for Software, 1 for QAT
    local mode_name="Software-Zstd"
    if [ "$use_qat" -eq 1 ]; then
        mode_name="QAT-Accelerated-Zstd"
    fi

    echo "=== Running Multi-Threaded Sweep for $mode_name ==="

    for t in "${THREADS_ARRAY[@]}"; do
        echo "Testing with $t Thread(s)..."
        
        local log_file="/tmp/zstd_run_${use_qat}_t${t}.log"
        rm -f "$log_file"

        export QAT_SECTION_NAME="UPSTREAM"

        if [ "$use_qat" -eq 1 ]; then
            numactl --cpunodebind=0 --membind=0 $ZSTD_BENCH -m1 -l5 -c$CHUNK_SIZE -t$t -L$COMPRESSION_LEVEL -E2 "$TEST_FILE" > "$log_file" 2>&1
        else
            numactl --cpunodebind=0 --membind=0 $ZSTD_BENCH -l5 -c$CHUNK_SIZE -t$t -L$COMPRESSION_LEVEL -E2 "$TEST_FILE" > "$log_file" 2>&1
        fi

        # Extract aggregate throughput metrics
        local comp_speed=$(awk -F'ALL Compression Speed:[ \t]*' '/ALL Compression Speed:/ {print $2}' "$log_file" | awk '{print $1}')
        local decomp_speed=$(awk -F'ALL Decompression Speed:[ \t]*' '/ALL Decompression Speed:/ {print $2}' "$log_file" | awk '{print $1}')

        # Extract sizes from the first thread's output (Format: Thread 1: Compression: 1073741824 -> 354989458,)
        local uncompressed_size=$(awk '/Thread 1: Compression:/ {print $4}' "$log_file" | head -n 1)
        # Grab the 6th field and strip the trailing comma
        local compressed_size=$(awk '/Thread 1: Compression:/ {print $6}' "$log_file" | tr -d ',' | head -n 1)

        # Calculate uncompressed_size / compressed_size
        local comp_ratio="N/A"
        if [[ -n "$uncompressed_size" && -n "$compressed_size" && "$compressed_size" -gt 0 ]]; then
            comp_ratio=$(awk -v u="$uncompressed_size" -v c="$compressed_size" 'BEGIN { printf "%.2f", u / c }')
        fi

        if [[ -z "$comp_speed" || -z "$decomp_speed" ]]; then
            echo "$mode_name,$t,ERR,ERR,ERR" >> $RESULTS_CSV
            echo "  [FAIL] Failed to extract performance metric. Check $log_file"
        else
            echo "$mode_name,$t,$comp_speed,$decomp_speed,$comp_ratio" >> $RESULTS_CSV
            printf "  Total Result -> Comp: %5s MB/s | Decomp: %5s MB/s | Ratio: %sx\n" "$comp_speed" "$decomp_speed" "$comp_ratio"
        fi
    done
}

# Run sweeps
# run_zstd_sweep 0
# echo "------------------------------------------------"
run_zstd_sweep 1
echo "------------------------------------------------"
echo "Saturation profile test complete. Results written directly to $RESULTS_CSV"