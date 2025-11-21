require_relative '../lib/harness/loader'

ARR = []

run_benchmark(500) do
  500_000.times do |i|
    # each is a 0-arg cfunc
    ARR.each {}
    # index is a variadic cfunc
    # Manually unrolling to avoid loop overhead
    ARR.index {}
    ARR.each {}
    ARR.index {}
    ARR.each {}
    ARR.index {}
    ARR.each {}
    ARR.index {}
    ARR.each {}
    ARR.index {}
    ARR.each {}
    ARR.index {}
    ARR.each {}
    ARR.index {}
    ARR.each {}
    ARR.index {}
    ARR.each {}
    ARR.index {}
    ARR.each {}
    ARR.index {}
    ARR.each {}
    ARR.index {}
  end
end
