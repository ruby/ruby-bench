require_relative '../lib/harness/loader'

def add(left:, right:)
  left + right
end

run_benchmark(400) do
  # 500K calls
  500_000.times do |i|
    # Call 10 times to reduce loop overhead, emphasize call performance
    add(left: 1, right: 0)
    add(left: 1, right: 1)
    add(left: 1, right: 2)
    add(left: 1, right: 3)
    add(left: 1, right: 4)
    add(left: 1, right: 5)
    add(left: 1, right: 6)
    add(left: 1, right: 7)
    add(left: 1, right: 8)
    add(left: 1, right: 9)
  end
end
