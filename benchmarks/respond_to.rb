# Microbenchmark to test the performance of respond_to?
# This is one of the top most called methods in rack/railsbench

require_relative '../lib/harness/loader'

class A
  def foo
  end

  def foo2
  end
end

class B < A
end

class C < A
end

run_benchmark(1000) do
  a = A.new
  b = B.new
  c = C.new

  # 500K calls
  500000.times do |i|
    # Call 12 times to reduce loop overhead, emphasize call performance
    a.respond_to?(:foo)
    a.respond_to?(:foo2)
    a.respond_to?(:bar)
    a.respond_to?(:bar2)
    b.respond_to?(:foo)
    b.respond_to?(:foo2)
    b.respond_to?(:bar)
    b.respond_to?(:bar2)
    c.respond_to?(:foo)
    c.respond_to?(:foo2)
    c.respond_to?(:bar)
    c.respond_to?(:bar2)
  end
end
