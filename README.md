# ADMS 2026 Evaluation

This repository contains the microbenchmarks used to characterize the In-Memory Analytics Accelerator (IAA) and QuickAssist Technology (QAT) on Intel Xeon 6 (Granite Rapids) platforms.

## Repository Structure
- `cpu_baseline_parallel.sh`: CPU baseline using lzbench.
- `iaa_parallel.sh`: IAA using Intel QPL.
- `qat_saturation_single_device.sh`: QAT using Intel QATzip
- `qat_zstd_saturation_single_device`: QAT for Zstd using Intel QAT-ZSTD-Plugin
- `measure_overhead_iaa.cpp`: IAA submission and polling latency.
- `measure_overhead_qat.cpp`: QAT end-to-end offloading overhead.

## Compilation
Ensure `libqpl` and `qatzip` are installed on your system.
g++ -O3 -march=native measure_overhead_iaa.cpp -lqpl -o measure_overhead_iaa
g++ -O3 -march=native measure_overhead_qat.cpp -lqatzip -o measure_overhead_qat