require_relative '../harness/loader'

# Call with and without args
define_method(:zero) { :b }
define_method(:one) { |arg| arg }

run_benchmark(500) do
  500_000.times do |i|
    # Manually unrolling to avoid loop overhead
    zero
    one 123
    zero
    one 123
    zero
    one 123
    zero
    one 123
    zero
    one 123
    zero
    one 123
    zero
    one 123
    zero
    one 123
    zero
    one 123
  end
end
