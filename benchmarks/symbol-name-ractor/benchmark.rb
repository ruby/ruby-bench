require_relative "../../harness/loader"

SYMBOL = :ruby_bench_id2str_pressure_static_symbol
EXPECTED_NAME = SYMBOL.name
ITERATIONS = Integer(ENV.fetch("SYMBOL_NAME_RACTOR_ITERS", 10_000_000))

run_benchmark(5) do |num_ractors = 0|
  iterations = num_ractors.zero? ? ITERATIONS : [ITERATIONS / num_ractors, 1].max

  name = nil
  i = 0
  while i < iterations
    name = SYMBOL.name
    i += 1
  end

  raise "unexpected Symbol#name result" unless name.equal?(EXPECTED_NAME)
end
