require_relative '../harness/loader'

class Point
  attr_reader :x, :y
  def initialize(x, y)
    @x = x
    @y = y
  end

  def ==(other)
    @x == other.x && @y == other.y
  end
end

def test
  Point.new(1, 2) == Point.new(1, 2)
end

run_benchmark(100) do
  i = 0
  while i < 1_000_000
    test
    i += 1
  end
end
