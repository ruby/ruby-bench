require 'benchmark'
require_relative "../harness/harness-common"

# Minimum number of benchmarking iterations
MAX_BENCH_ITRS = Integer(ENV.fetch('MAX_BENCH_ITRS', 1000))

# Minimum benchmarking time in seconds
MAX_BENCH_SECONDS = Integer(ENV.fetch('MAX_BENCH_SECONDS', 60 * 60))

puts RUBY_DESCRIPTION

# Takes a block as input
def run_benchmark(_num_itrs_hint, **, &blk)
  times = []
  total_time = 0
  num_itrs = 0

  begin
    time = Benchmark.realtime { yield }
    num_itrs += 1

    time_ms = (1000 * time).to_i
    puts "itr \##{num_itrs}: #{time_ms}ms"

    times << time
    total_time += time
  end until num_itrs >= MAX_BENCH_ITRS || total_time >= MAX_BENCH_SECONDS

  return_results([], times)
end
