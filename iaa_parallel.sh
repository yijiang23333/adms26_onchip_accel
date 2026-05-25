#!/bin/bash

QPL_BENCH="/scratch/yijiang/qpl/build/tools/benchmarks/qpl_benchmarks"
DATASET="/scratch/yijiang/tpch-dbgen/tpch-sf10/lineitem_100M.tbl"
RESULTS="iaa_saturation.csv"

BLOCK_BYTES=(8192 32768 131072 524288 2097152)
# BLOCK_BYTES=(4096 8192 16384 32768 65536 131072 262144 524288 1048576 2097152)
# THREADS=(1 2 4 8 16 32 64 96)
THREADS=(1 96)
MODE="dynamic"

# Updated CSV Header
echo "BlockSize_KB,Processes,PerProcess_Comp_MBps,Total_Comp_MBps,Total_Decomp_MBps,Ratio" > $RESULTS

filename=$(basename "$DATASET")
TEMP_DIR=$(mktemp -d -p "$(dirname "$DATASET")")
ln "$DATASET" "$TEMP_DIR/$filename"

echo "Starting Full Multi-Process Hardware Saturation Sweep..."

for size in "${BLOCK_BYTES[@]}"; do
    size_kb=$((size / 1024))
    
    for t in "${THREADS[@]}"; do
        echo -n "-> Testing Block Size: ${size_kb}KB | Concurrent Processes: ${t} ... "
        
        # ==========================================
        # PHASE 1: COMPRESSION
        # ==========================================
        for ((i=1; i<=t; i++)); do
            prlimit --memlock=unlimited:unlimited numactl --cpunodebind=0 --membind=0 $QPL_BENCH \
                --dataset="$TEMP_DIR" \
                --block_size=$size \
                --benchmark_filter="deflate.*:iaa.*:sync.*:${MODE}.*" \
                --benchmark_min_time=1x > "/tmp/qpl_comp_${i}.txt" 2>&1 &
        done
        wait
        
        # ==========================================
        # PHASE 2: DECOMPRESSION
        # ==========================================
        for ((i=1; i<=t; i++)); do
            prlimit --memlock=unlimited:unlimited numactl --cpunodebind=0 --membind=0 $QPL_BENCH \
                --dataset="$TEMP_DIR" \
                --block_size=$size \
                --benchmark_filter="inflate.*:iaa.*:sync.*:${MODE}.*" \
                --benchmark_min_time=1x > "/tmp/qpl_decomp_${i}.txt" 2>&1 &
        done
        wait
        
        # ==========================================
        # PHASE 3: PARSE AND AGGREGATE
        # ==========================================
        total_comp=0
        total_decomp=0
        sum_ratio=0
        
        for ((i=1; i<=t; i++)); do
            # Extract Comp Speed (Aware of M/s vs G/s)
            c_speed=$(grep -oP 'Throughput=\K[0-9.]+[A-Za-z]?' "/tmp/qpl_comp_${i}.txt" | awk '{
                val = $1;
                num = val + 0;
                if (val ~ /G/ || val ~ /g/) num *= 1024;
                else if (val ~ /K/ || val ~ /k/) num /= 1024;
                sum += num;
                cnt++;
            } END { if(cnt>0) print sum/cnt; else print 0 }')
            total_comp=$(awk "BEGIN {print $total_comp + $c_speed}")
            
            # Extract Decomp Speed (Aware of M/s vs G/s)
            d_speed=$(grep -oP 'Throughput=\K[0-9.]+[A-Za-z]?' "/tmp/qpl_decomp_${i}.txt" | awk '{
                val = $1;
                num = val + 0;
                if (val ~ /G/ || val ~ /g/) num *= 1024;
                else if (val ~ /K/ || val ~ /k/) num /= 1024;
                sum += num;
                cnt++;
            } END { if(cnt>0) print sum/cnt; else print 0 }')
            total_decomp=$(awk "BEGIN {print $total_decomp + $d_speed}")
            
            # Extract Average Compression Ratio
            ratio=$(grep -oP 'Ratio=\K[0-9.]+' "/tmp/qpl_comp_${i}.txt" | awk '{sum+=$1; cnt++} END {if(cnt>0) print sum/cnt; else print 0}')
            sum_ratio=$(awk "BEGIN {print $sum_ratio + $ratio}")
            
            rm -f "/tmp/qpl_comp_${i}.txt" "/tmp/qpl_decomp_${i}.txt"
        done
        
        avg_per_proc=0
        avg_ratio=0
        if [ "$t" -gt 0 ]; then
            avg_per_proc=$(awk "BEGIN {print $total_comp / $t}")
            avg_ratio=$(awk "BEGIN {print $sum_ratio / $t}")
        fi
        
        echo "$size_kb,$t,$avg_per_proc,$total_comp,$total_decomp,$avg_ratio" >> $RESULTS
        
        printf "Done!\n     Comp: %.2f MB/s | Decomp: %.2f MB/s | Ratio: %.2f\n" "$total_comp" "$total_decomp" "$avg_ratio"
    done
done

rm -rf "$TEMP_DIR"
echo "Saturation sweep complete. Results saved to $RESULTS"