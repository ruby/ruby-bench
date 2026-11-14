# frozen_string_literal: true

# Profile only the measured iterations with Callgrind (not setup or warmup).
# Usage:
# WARMUP_ITRS=10 MIN_BENCH_ITRS=1 HARNESS=callgrind \
#   valgrind --tool=callgrind --instr-atstart=no ruby benchmarks/fib.rb
# Use --callgrind-out-file=/absolute/path/callgrind.out.%p to choose the output.

require_relative "../lib/harness"
require_relative "../lib/harness/extra"
require "rbconfig"

# Valgrind client requests are silent no-ops outside Valgrind, so without
# this check a run without Callgrind would succeed with no profile.
raise "callgrind unsupported" unless RbConfig::CONFIG["host_os"].include?("linux")
# Valgrind fakes argv and /proc/self/exe, but the kernel's process name is
# the tool binary (e.g. "callgrind-amd64").
unless File.read("/proc/self/comm").start_with?("callgrind-")
  raise "harness/callgrind.rb must run under `valgrind --tool=callgrind` " \
        "(e.g. ./run_benchmarks.rb --harness=callgrind)"
end

# Load before benchmark Bundler setup can hide globally installed gems.
ensure_global_gem("valgrind")
require "valgrind"

# Also exclude setup when the caller forgot --instr-atstart=no.
Valgrind.callgrind_stop_instrumentation

def run_benchmark(num_itrs_hint, **, &block)
  warmup_itrs = Integer(ENV.fetch('WARMUP_ITRS', 10))
  bench_itrs = Integer(ENV.fetch('MIN_BENCH_ITRS', num_itrs_hint))
  raise ArgumentError, 'WARMUP_ITRS must be non-negative' if warmup_itrs < 0
  raise ArgumentError, 'MIN_BENCH_ITRS must be positive' if bench_itrs <= 0

  warmup = []
  bench = []
  Valgrind.callgrind_stop_instrumentation
  warmup_itrs.times do
    start = get_time
    block.call
    warmup << get_time - start
  end

  name = benchmark_name
  begin
    Valgrind.callgrind_zero_stats
    Valgrind.callgrind_start_instrumentation
    bench_itrs.times do
      start = get_time
      block.call
      bench << get_time - start
    end
  ensure
    # Preserve a partial profile on failure, but never leave instrumentation on.
    # Dump before stopping so the summary line matches the totals; zero this thread so its exit dump is empty.
    Valgrind.callgrind_dump_stats(name)
    Valgrind.callgrind_stop_instrumentation
    Valgrind.callgrind_zero_stats
  end

  puts "Callgrind stats dumped for #{name} (output controlled by --callgrind-out-file)."
  return_results(warmup, bench) if ENV['RESULT_JSON_PATH']
end
