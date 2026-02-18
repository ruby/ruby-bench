# frozen_string_literal: true
#
# Harness for profiling with Valgrind's callgrind tool.
# Warmup runs with instrumentation off (full speed), then callgrind
# instrumentation is enabled for benchmark iterations only.
#
# Example usage:
#
#   WARMUP_ITRS=15 MIN_BENCH_ITRS=5 valgrind --tool=callgrind \
#     --instr-atstart=no --callgrind-out-file=callgrind.out \
#     ~/.rubies/ruby-master/bin/ruby --zjit -Iharness-callgrind \
#     benchmarks/lobsters/benchmark.rb
#
# This produces a single output file containing only benchmark
# iteration data (no warmup/compilation overhead).
#
# Analyze with:
#   callgrind_annotate callgrind.out
#   kcachegrind callgrind.out
#
# Use low iteration counts — callgrind imposes ~20-50x slowdown
# on the instrumented (benchmark) phase. The warmup phase runs
# at near-native speed since instrumentation is off.
#
# To verify only benchmark data was collected, check that the file
# says "part 1" and "Trigger: Program termination" — no prior dumps
# means no warmup data was included.

require_relative "../harness/harness-common"

# Run $WARMUP_ITRS or 15 warmup iterations, then $MIN_BENCH_ITRS or
# `num_itrs_hint` benchmark iterations. Instrumentation is toggled on
# after warmup via `callgrind_control`.
def run_benchmark(num_itrs_hint, **, &blk)
  warmup_itrs = Integer(ENV.fetch('WARMUP_ITRS', 15))
  bench_itrs = Integer(ENV.fetch('MIN_BENCH_ITRS', num_itrs_hint))

  # Run warmup with instrumentation off (near-native speed).
  # Requires: valgrind --tool=callgrind --instr-atstart=no
  i = 0
  while i < warmup_itrs
    yield
    i += 1
  end

  # Turn instrumentation on for the benchmark phase.
  pid = Process.pid.to_s
  ok = system("callgrind_control", "-i", "on", pid,
              out: File::NULL, err: File::NULL)
  if ok
    warn "harness-callgrind: Instrumentation enabled after #{warmup_itrs} warmup iterations."
  else
    abort "harness-callgrind: callgrind_control failed (not running under callgrind?)."
  end

  # Run benchmark (instrumented)
  i = 0
  while i < bench_itrs
    yield
    i += 1
  end

  # Turn instrumentation off to exclude shutdown/cleanup from the profile.
  system("callgrind_control", "-i", "off", pid,
         out: File::NULL, err: File::NULL)
end
