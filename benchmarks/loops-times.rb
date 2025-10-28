require_relative '../harness/loader'

# Fix these values for determinism
U = 5
R = 7

run_benchmark(10) do
  u = U
  r = R
  a = Array.new(10000, 0)

  4_000.times do |i|
    4_000.times do |j|
      a[i] += j % u
    end
    a[i] += r
  end

  result = a[r]
  if result != 8007
    raise "incorrect result"
  end
end
