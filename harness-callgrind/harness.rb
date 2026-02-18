# frozen_string_literal: true
#
# Harness for profiling with Valgrind's callgrind tool.
# Warmup runs with instrumentation off (full speed), then callgrind
# instrumentation is enabled for benchmark iterations only.
#
# CALLGRIND_OUT_FILE sets the output filename. Valgrind's %q{}
# expansion reads it too, so there's a single source of truth.
#
# Example usage (steady-state only):
#
#   CALLGRIND_OUT_FILE=callgrind.out \
#     WARMUP_ITRS=15 MIN_BENCH_ITRS=5 valgrind --tool=callgrind \
#     --instr-atstart=no \
#     --callgrind-out-file=%q{CALLGRIND_OUT_FILE} \
#     ~/.rubies/ruby-master/bin/ruby --zjit -Iharness-callgrind \
#     benchmarks/lobsters/benchmark.rb
#
# This produces a single output file containing only benchmark
# iteration data (no warmup/compilation overhead).
#
# To also capture warmup/compilation activity in a separate file,
# add CALLGRIND_PROFILE_WARMUP=1:
#
#   CALLGRIND_OUT_FILE=callgrind.out CALLGRIND_PROFILE_WARMUP=1 \
#     WARMUP_ITRS=15 MIN_BENCH_ITRS=5 valgrind --tool=callgrind \
#     --instr-atstart=no \
#     --callgrind-out-file=%q{CALLGRIND_OUT_FILE} \
#     ~/.rubies/ruby-master/bin/ruby --zjit -Iharness-callgrind \
#     benchmarks/lobsters/benchmark.rb
#
# This produces two files:
#   callgrind-warmup.out  — warmup/compilation profile
#   callgrind.out         — steady-state benchmark profile
#
# Note: warmup runs ~20-50x slower when CALLGRIND_PROFILE_WARMUP is
# set because callgrind instrumentation is active during warmup.
#
# Analyze with:
#   callgrind_annotate callgrind.out
#   kcachegrind callgrind.out
#
# Use low iteration counts — callgrind imposes ~20-50x slowdown
# on instrumented phases. Without CALLGRIND_PROFILE_WARMUP, warmup
# runs at near-native speed since instrumentation is off.

require_relative "../harness/harness-common"

def callgrind_control(*args, pid)
  system("callgrind_control", *args, pid,
         out: File::NULL, err: File::NULL)
end

# Run $WARMUP_ITRS or 15 warmup iterations, then $MIN_BENCH_ITRS or
# `num_itrs_hint` benchmark iterations. Instrumentation is toggled
# via `callgrind_control`.
#
# When CALLGRIND_PROFILE_WARMUP is set, warmup is instrumented and
# dumped to a separate file before the benchmark phase begins.
def run_benchmark(num_itrs_hint, **, &blk)
  warmup_itrs = Integer(ENV.fetch('WARMUP_ITRS', 15))
  bench_itrs = Integer(ENV.fetch('MIN_BENCH_ITRS', num_itrs_hint))
  profile_warmup = !!ENV['CALLGRIND_PROFILE_WARMUP']
  callgrind_out = ENV.fetch('CALLGRIND_OUT_FILE', 'callgrind.out')

  pid = Process.pid.to_s

  if profile_warmup
    # Turn instrumentation on to capture compilation/JIT activity
    # during warmup. Requires: valgrind --instr-atstart=no
    ok = callgrind_control("-i", "on", pid)
    unless ok
      abort "harness-callgrind: callgrind_control failed (not running under callgrind?)."
    end
  end

  # Run warmup iterations.
  # With CALLGRIND_PROFILE_WARMUP: instrumented (~20-50x slower).
  # Without: uninstrumented (near-native speed).
  i = 0
  while i < warmup_itrs
    yield
    i += 1
  end

  if profile_warmup
    # Dump warmup data — counters are automatically zeroed so the
    # benchmark phase starts with a clean slate.
    callgrind_control("-d", pid)

    # callgrind writes the dump as <outfile>.1. Rename it so it has
    # a descriptive name and loads cleanly in tools like KCachegrind.
    dump_file = "#{callgrind_out}.1"
    warmup_file = callgrind_out.sub(/\.out\z/, "-warmup.out")
    if File.exist?(dump_file)
      File.rename(dump_file, warmup_file)
      warn "harness-callgrind: Warmup data dumped to #{warmup_file} after #{warmup_itrs} iterations."
    else
      warn "harness-callgrind: Warmup data dumped after #{warmup_itrs} iterations (could not find #{dump_file} to rename)."
    end
  else
    # Turn instrumentation on for the benchmark phase only.
    ok = callgrind_control("-i", "on", pid)
    unless ok
      abort "harness-callgrind: callgrind_control failed (not running under callgrind?)."
    end
  end

  warn "harness-callgrind: Instrumentation enabled for #{bench_itrs} benchmark iterations."

  # Run benchmark (instrumented).
  i = 0
  while i < bench_itrs
    yield
    i += 1
  end

  # Turn instrumentation off to exclude shutdown/cleanup from the
  # profile. Benchmark data is written to <outfile> at program exit.
  callgrind_control("-i", "off", pid)
end
