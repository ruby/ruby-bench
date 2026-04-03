require_relative '../harness/loader'

ARR = []

run_benchmark(500) do
  500_000.times do |i|
    # reverse_each is a 0-arg cfunc
    ARR.reverse_each {}
    # index is a variadic cfunc
    # Manually unrolling to avoid loop overhead
    ARR.index {}
    ARR.reverse_each {}
    ARR.index {}
    ARR.reverse_each {}
    ARR.index {}
    ARR.reverse_each {}
    ARR.index {}
    ARR.reverse_each {}
    ARR.index {}
    ARR.reverse_each {}
    ARR.index {}
    ARR.reverse_each {}
    ARR.index {}
    ARR.reverse_each {}
    ARR.index {}
    ARR.reverse_each {}
    ARR.index {}
    ARR.reverse_each {}
    ARR.index {}
    ARR.reverse_each {}
    ARR.index {}
  end
end
