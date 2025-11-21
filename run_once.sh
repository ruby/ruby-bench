#!/usr/bin/env bash
# Script to run a single benchmark once
# You can pass --yjit-stats and other ruby arguments to this script.
# Automatically detects Ractor benchmarks and uses the appropriate harness.
# Examples:
#   ./run_once.sh --yjit-stats benchmarks/railsbench/benchmark.rb
#   ./run_once.sh benchmarks-ractor/optcarrot/benchmark.rb

# Detect if any argument contains benchmarks-ractor/ to determine harness
HARNESS_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == *"benchmarks-ractor/"* ]]; then
        HARNESS_ARGS=("-r" "ractor")
        break
    fi
done

WARMUP_ITRS=0 MIN_BENCH_ITRS=1 MIN_BENCH_TIME=0 ruby -I"./harness" "${HARNESS_ARGS[@]}" "$@"