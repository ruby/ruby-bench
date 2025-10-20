require_relative '../harness/loader'

ARR = []

run_benchmark(500) do
  2_000_000.times do |i|
    # each is a 0-arg cfunc
    ARR.each {}
    # index is a variadic cfunc
    ARR.index {}
  end
end
