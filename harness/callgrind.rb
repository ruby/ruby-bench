# frozen_string_literal: true

# Profile only the measured iterations with Callgrind (not setup or warmup),
# and report each iteration's instruction count (Ir) alongside its time.
# Usage:
# WARMUP_ITRS=10 MIN_BENCH_ITRS=1 HARNESS=callgrind \
#   valgrind --tool=callgrind --instr-atstart=no ruby benchmarks/fib.rb
# To choose the output, set VALGRIND_OPTS=--callgrind-out-file=/path/callgrind.out.%p
# rather than passing the flag: the harness reads each iteration's dump back,
# and Valgrind hides its command line (but not its environment) from the program.

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

# The last occurrence wins, as in Valgrind. Like Callgrind, resolve relative
# paths (including the default) against the startup directory, which this is
# loaded in before benchmark setup can chdir.
CALLGRIND_OUT_FILE = File.expand_path(
  ENV.fetch("VALGRIND_OPTS", "")[/.*--callgrind-out-file=(\S+)/, 1] || "callgrind.out.%p"
).gsub("%p", Process.pid.to_s)

# Load before benchmark Bundler setup can hide globally installed gems.
ensure_global_gem("valgrind")
require "valgrind"

# Also exclude setup when the caller forgot --instr-atstart=no.
Valgrind.callgrind_stop_instrumentation

# Every client-requested dump goes to "<out file>.<part>", with parts numbered
# from 1 within the process. The file is complete when the request returns.
def callgrind_dump_ir(description)
  $callgrind_dump_part = ($callgrind_dump_part || 0) + 1
  Valgrind.callgrind_dump_stats(description)
  # `summary:` can be garbage when instrumentation starts mid-call; `totals:`
  # is reliable. Ir is the first event.
  path = "#{CALLGRIND_OUT_FILE}.#{$callgrind_dump_part}"
  unless File.exist?(path)
    raise "callgrind dump not found at #{path}; pass --callgrind-out-file via VALGRIND_OPTS, not on the command line"
  end
  totals = File.binread(path)[/^totals: (\d+)/, 1]
  raise "no totals in callgrind dump #{path}" unless totals
  Integer(totals)
end

def run_benchmark(num_itrs_hint, **, &block)
  warmup_itrs = Integer(ENV.fetch('WARMUP_ITRS', 10))
  bench_itrs = Integer(ENV.fetch('MIN_BENCH_ITRS', num_itrs_hint))
  raise ArgumentError, 'WARMUP_ITRS must be non-negative' if warmup_itrs < 0
  raise ArgumentError, 'MIN_BENCH_ITRS must be positive' if bench_itrs <= 0

  warmup = []
  bench = []
  instructions = []
  Valgrind.callgrind_stop_instrumentation
  warmup_itrs.times do
    start = get_time
    block.call
    warmup << get_time - start
  end

  begin
    # Switching instrumentation discards every translation, so do it once and
    # zero the counters before each iteration instead. Each dump then holds
    # one iteration (plus the few instructions of the client requests).
    Valgrind.callgrind_start_instrumentation

    bench_itrs.times do |i|
      start = get_time
      Valgrind.callgrind_zero_stats
      begin
        block.call
      ensure
        # Preserve a partial profile on failure.
        elapsed = get_time - start
        ir = callgrind_dump_ir("#{benchmark_name} itr #{i}")
      end
      bench << elapsed
      instructions << ir
    end
  ensure
    Valgrind.callgrind_stop_instrumentation
  end

  puts "Callgrind stats dumped for #{benchmark_name} to #{CALLGRIND_OUT_FILE}.<part>."
  if ENV['RESULT_JSON_PATH']
    return_results(warmup, bench, metrics: { "instructions" => { "bench" => instructions } }, primary_metric: "instructions")
  end
end
