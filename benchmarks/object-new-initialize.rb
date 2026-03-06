require_relative '../harness/loader'

class C
  def initialize(a, b, c, d)
    @a = a
    @b = b
    @c = c
    @d = d
  end
end

def test
  C.new(1, 2, 3, 4)
end

run_benchmark(100) do
  i = 0
  while i < 1_000_000
    test
    i += 1
  end
end
