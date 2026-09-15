require_relative '../harness/loader'

Point = Struct.new(:x, :y)

def test
  p = Point.new(1, 2)
  p.x + p.y
end

run_benchmark(100) do
  i = 0
  while i < 1_000_000
    test
    i += 1
  end
end

