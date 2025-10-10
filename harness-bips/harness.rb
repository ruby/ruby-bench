require 'benchmark/ips'
require_relative "../harness/harness-common"

puts RUBY_DESCRIPTION

def run_benchmark(_, **, &block)
  Benchmark.ips do |x|
    x.report 'benchmark', &block
  end
  return_results([], [1.0])
end
