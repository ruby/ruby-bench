require_relative '../harness/loader'

ARR = []

run_benchmark(500) do
  2_000_000.times do |i|
    ARR.each {}
  end
end
