#include <iostream>
#include <vector>
#include <numeric>
#include <cstring>
#include <iomanip>
#include <x86intrin.h>
#include <qatzip.h>

using namespace std;

// Set to your locked base CPU frequency
const double CPU_FREQ_GHZ = 2.1; 

int main() {
    QzSession_T qz_session;
    if (qzInit(&qz_session, false) != QZ_OK) {
        cerr << "FATAL: Failed to initialize QAT. Check qat_service and drivers.\n";
        return 1;
    }

    QzSessionParams_T params;
    memset(&params, 0, sizeof(QzSessionParams_T));
    qzGetDefaults(&params);
    params.comp_algorithm = QZ_DEFLATE;
    params.data_fmt = QZ_DEFLATE_RAW;
    
    if (qzSetupSession(&qz_session, &params) != QZ_OK) {
        cerr << "FATAL: Failed to setup QAT session.\n";
        return 1;
    }

    // Sweep sizes from 4KB to 4MB
    vector<size_t> block_sizes;
    block_sizes.push_back(4096);        // 4 KB
    block_sizes.push_back(8192);        // 8 KB
    block_sizes.push_back(16384);       // 16 KB
    block_sizes.push_back(32768);       // 32 KB
    block_sizes.push_back(65536);       // 64 KB
    block_sizes.push_back(131072);      // 128 KB
    block_sizes.push_back(262144);      // 256 KB
    block_sizes.push_back(524288);      // 512 KB
    block_sizes.push_back(1048576);     // 1 MB

    const int WARMUP_ITERATIONS = 50;
    const int MEASURE_ITERATIONS = 2000;

    cout << left << setw(10) << "Size" 
         << setw(20) << "Total RTT (cycles)" 
         << setw(20) << "Total RTT (us)" << "\n";
    cout << "--------------------------------------------------\n";

    for (size_t size_idx = 0; size_idx < block_sizes.size(); ++size_idx) {
        size_t current_size = block_sizes.at(size_idx);
        
        // QAT requires pinned/contiguous memory for maximum DMA efficiency.
        // aligned_alloc satisfies the user-space boundary.
        uint8_t* src = (uint8_t*)aligned_alloc(4096, current_size);
        size_t dest_bound = current_size * 2; 
        uint8_t* dst = (uint8_t*)aligned_alloc(4096, dest_bound);
        
        memset(src, 0xAA, current_size);
        memset(dst, 0, dest_bound);

        vector<uint64_t> total_cycles;
        total_cycles.reserve(MEASURE_ITERATIONS);

        // --- WARMUP ---
        // Wakes up the QAT polling threads and establishes DMA mappings
        for (int i = 0; i < WARMUP_ITERATIONS; ++i) {
            uint32_t comp_len = dest_bound;
            qzCompress(&qz_session, src, (uint32_t*)&current_size, dst, &comp_len, 1);
        }

        // --- MEASUREMENT ---
        for (int i = 0; i < MEASURE_ITERATIONS; ++i) {
            uint32_t comp_len = dest_bound;
            
            uint64_t t0 = __rdtsc();
            int rc = qzCompress(&qz_session, src, (uint32_t*)&current_size, dst, &comp_len, 1);
            uint64_t t1 = __rdtsc();

            if (rc == QZ_OK) {
                total_cycles.push_back(t1 - t0);
            } else {
                cerr << "Compression failed on size " << current_size << "\n";
                exit(1);
            }
        }

        auto calc_avg = [](const vector<uint64_t>& v) {
            if (v.empty()) return 0ULL;
            return accumulate(v.begin(), v.end(), 0ULL) / v.size();
        };

        uint64_t avg_tot = calc_avg(total_cycles);
        double avg_us = (avg_tot / CPU_FREQ_GHZ) / 1000.0; // Convert ns to us

        // Print row for this block size
        string size_label = to_string(current_size / 1024) + " KB";
        cout << left << setw(10) << size_label 
             << setw(20) << avg_tot 
             << setw(20) << fixed << setprecision(3) << avg_us << "\n";

        free(src);
        free(dst);
    }

    qzClose(&qz_session);
    return 0;
}