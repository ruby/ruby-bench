# frozen_string_literal: true
#
# This is a relatively minimal harness meant for use with Linux perf(1).
# Example usage:
#
#    $ PERF='record -e cycles' ruby -Iharness-perf benchmarks/fib.rb
#
# When recording with perf(1), make sure the benchmark runs long enough; you
# can tweak the MIN_BENCH_ITRS environment variable to lengthen the run. A race
# condition is possible where the benchmark finishes before the perf(1)
# subprocess has a chance to attach, in which case perf outputs no profile.

require_relative "../harness/harness-common"

# Run $WARMUP_ITRS or 10 iterations of a given block. Then run $MIN_BENCH_ITRS
# or `num_itrs_int` iterations of the block, attaching a perf command to the
# benchmark process.
#
# `num_itrs_hint` should be close to what the default harness would use as
# the number of benchmark iterations. For example, if the default harness runs
# 10 benchmark iterations (after 15 warmup iterations) for a benchmark with
# the default MIN_BENCH_TIME, the benchmark should have 10 as `num_itrs_hint`.
def run_benchmark(num_itrs_hint, **, &blk)
  warmup_itrs = Integer(ENV.fetch('WARMUP_ITRS', 10))
  bench_itrs = Integer(ENV.fetch('MIN_BENCH_ITRS', num_itrs_hint))

  # Run warmup
  i = 0
  while i < warmup_itrs
    yield
    i += 1
  end

  # Start perf after warmup
  if ENV['PERF']
    cmd = ['perf', *ENV['PERF'].split(' '), '-p', Process.pid.to_s]
    if cmd[1] == 'record'
      # Put perf.data in the same place, ignoring Dir.chdir
      cmd.push('-o', File.expand_path('../perf.data', __dir__))
    end
    pid = Process.spawn(*cmd)
    # _Race_: we, the parent process might finish before perf attaches.
    # Ideally, we would wait for attachment before running benchmark
    # iterations, but implementing that seems complicated.
  end

  # Run benchmark
  i = 0
  while i < bench_itrs
    yield
    i += 1
  end
ensure
  if pid
    Process.kill(:INT, pid)
    Process.wait(pid)
  end
end
