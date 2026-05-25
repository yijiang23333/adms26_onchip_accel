#include <iostream>
#include <vector>
#include <numeric>
#include <cstring>
#include <iomanip>
#include <x86intrin.h>
#include <qpl/qpl.h>

using namespace std;

// Adjust this to your CPU's locked base clock frequency for accurate nanosecond conversion
const double CPU_FREQ_GHZ = 2.1; 

int main() {
    uint32_t job_size = 0;
    qpl_get_job_size(qpl_path_hardware, &job_size);
    uint8_t* job_buffer = (uint8_t*)aligned_alloc(64, job_size);
    qpl_job* job = reinterpret_cast<qpl_job*>(job_buffer);

    if (qpl_init_job(qpl_path_hardware, job) != QPL_STS_OK) {
        cerr << "FATAL: Failed to initialize IAA job. Check idxd driver.\n";
        return 1;
    }

    // Sweep sizes from 4KB to 1MB
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

    const int WARMUP_ITERATIONS = 100;
    const int MEASURE_ITERATIONS = 5000;

    cout << left << setw(10) << "Size" 
         << setw(15) << "Sub (cycles)" 
         << setw(15) << "Sub (ns)" 
         << setw(15) << "Poll (cycles)" 
         << setw(15) << "Poll (ns)" << "\n";
    cout << "----------------------------------------------------------------------\n";

    for (size_t size_idx = 0; size_idx < block_sizes.size(); ++size_idx) {
        size_t current_size = block_sizes.at(size_idx);
        
        // Allocate and physically map memory for this block size
        uint8_t* src = (uint8_t*)aligned_alloc(4096, current_size);
        size_t dest_bound = current_size * 2; 
        uint8_t* dst = (uint8_t*)aligned_alloc(4096, dest_bound);
        
        memset(src, 0xAA, current_size);
        memset(dst, 0, dest_bound);

        vector<uint64_t> submission_cycles;
        vector<uint64_t> polling_cycles;
        submission_cycles.reserve(MEASURE_ITERATIONS);
        polling_cycles.reserve(MEASURE_ITERATIONS);

        // --- WARMUP ---
        for (int i = 0; i < WARMUP_ITERATIONS; ++i) {
            job->op = qpl_op_compress;
            job->level = qpl_default_level;
            job->next_in_ptr = src;
            job->available_in = current_size;
            job->next_out_ptr = dst;
            job->available_out = dest_bound;
            job->flags = QPL_FLAG_FIRST | QPL_FLAG_LAST | QPL_FLAG_OMIT_VERIFY;
            job->total_in = 0;
            job->total_out = 0;

            qpl_status status;
            int retries = 0;
            do {
                status = qpl_execute_job(job);
                if (status == 503) { retries++; _mm_pause(); }
            } while (status == 503 && retries < 10000);
        }

        // --- MEASUREMENT ---
        for (int i = 0; i < MEASURE_ITERATIONS; ++i) {
            // Re-arm descriptor
            job->op = qpl_op_compress;
            job->level = qpl_default_level;
            job->next_in_ptr = src;
            job->available_in = current_size;
            job->next_out_ptr = dst;
            job->available_out = dest_bound;
            job->flags = QPL_FLAG_FIRST | QPL_FLAG_LAST | QPL_FLAG_OMIT_VERIFY;
            job->total_in = 0;
            job->total_out = 0;

            // 1. Measure Submission (CPU ENQCMD Overhead)
            uint64_t sub_start = __rdtsc();
            qpl_status sub_status;
            int retries = 0;
            do {
                sub_status = qpl_submit_job(job);
                if (sub_status == 503) { retries++; _mm_pause(); }
            } while (sub_status == 503 && retries < 100000);
            uint64_t sub_end = __rdtsc();

            if (sub_status != QPL_STS_OK) {
                cerr << "Submission failed: " << sub_status << "\n"; exit(1);
            }

            // 2. Measure Polling (Hardware Time + PCIe RTT)
            uint64_t poll_start = __rdtsc();
            qpl_status wait_status = qpl_wait_job(job);
            uint64_t poll_end = __rdtsc();

            if (wait_status == QPL_STS_OK) {
                submission_cycles.push_back(sub_end - sub_start);
                polling_cycles.push_back(poll_end - poll_start);
            }
        }

        auto calc_avg = [](const vector<uint64_t>& v) {
            if (v.empty()) return 0ULL;
            return accumulate(v.begin(), v.end(), 0ULL) / v.size();
        };

        uint64_t avg_sub = calc_avg(submission_cycles);
        uint64_t avg_poll = calc_avg(polling_cycles);

        // Print row for this block size
        string size_label = to_string(current_size / 1024) + " KB";
        cout << left << setw(10) << size_label 
             << setw(15) << avg_sub 
             << setw(15) << (uint64_t)(avg_sub / CPU_FREQ_GHZ) 
             << setw(15) << avg_poll 
             << setw(15) << (uint64_t)(avg_poll / CPU_FREQ_GHZ) << "\n";

        free(src);
        free(dst);
    }

    qpl_fini_job(job);
    free(job_buffer);
    return 0;
}