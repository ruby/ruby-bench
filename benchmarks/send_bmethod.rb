require_relative '../harness/loader'

# Call with and without args
define_method(:zero) { :b }
define_method(:one) { |arg| arg }

run_benchmark(500) do
  2_000_000.times do |i|
    zero
    one 123
  end
end
