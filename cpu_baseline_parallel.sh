#!/bin/bash

# Configuration
LZBENCH_BIN="/scratch/yijiang/lzbench/lzbench"
ROW_DATA="/scratch/yijiang/tpch-dbgen/tpch-sf10/lineitem.tbl"
COL_DIR="/scratch/yijiang/tpch-dbgen/tpch-sf10/col_lineitem"

# Algorithms and Block Sizes
# COMPRESSORS="libdeflate,1/lz4/zstd,1"
COMPRESSORS="slz_deflate"
BLOCK_SIZES_KB=(4 8 16 32 64 128 256 512 1024 2048)
# BLOCK_SIZES_KB=(2048)

# Thread counts to test (Scaling up to the 96 physical cores of Node 0)
# THREAD_COUNTS=(2 4 8 16 32 48 64 80 96)
THREAD_COUNTS=(1 96)

# Function to run benchmarks for a specific thread count
run_workload() {
    local threads=$1
    local format_label=$2
    local file_path=$3
    local csv_file=$4
    local filename=$(basename "$file_path")

    echo " -> [T$threads] Processing $format_label: $filename"

    for size in "${BLOCK_SIZES_KB[@]}"; do
        # Use numactl to keep execution and memory local to Node 0
        # -T specifies the thread pool size
        # -i5,5 and -t3,3 ensure stability
        numactl --cpunodebind=0 --membind=0 $LZBENCH_BIN \
            -e$COMPRESSORS \
            -b$size \
            -T$threads \
            -i5,5 -t3,3 \
            -o4 -q "$file_path" | tail -n +2 | while IFS= read -r line; do
            
            # Prepend metadata to lzbench CSV output
            echo "$format_label,$filename,$size,$threads,$line" >> "$csv_file"
        done
    done
}

# Main Loop over Thread Counts
for T in "${THREAD_COUNTS[@]}"; do
    RESULTS_CSV="cpu_parallel_T${T}.csv"
    echo "================================================="
    echo "Starting Benchmark Suite for $T Threads"
    echo "Results: $RESULTS_CSV"
    echo "================================================="

    # Initialize Header for this thread count's CSV
    echo "Format,Dataset,BlockSize_KB,Threads,Compressor,Comp_MBps,Decomp_MBps,OrigSize,CompSize,Ratio" > "$RESULTS_CSV"

    # 1. Row-Store execution
    if [ -f "$ROW_DATA" ]; then
        run_workload "$T" "RowStore" "$ROW_DATA" "$RESULTS_CSV"
    fi

    # 2. Column-Store execution
    # if [ -d "$COL_DIR" ]; then
    #     for col_file in "$COL_DIR"/*.dat; do
    #         if [ -f "$col_file" ]; then
    #             run_workload "$T" "ColStore" "$col_file" "$RESULTS_CSV"
    #         fi
    #     done
    # fi
    
    echo "Done with T$T."
    echo ""
done

echo "Parallel benchmarking complete. Results separated by thread count."