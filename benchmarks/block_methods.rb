require_relative '../harness/loader'

def array_each(array)
  array.each do |x|
    x * 2
  end
  array.each do |x|
    x * 4
  end
end

def array_map(array)
  array.map do |x|
    x * 2
  end
  array.map do |x|
    x * 4
  end
end

def array_select(array)
  array.select do |x|
    x.even?
  end
  array.select do |x|
    x.odd?
  end
end

def integer_times(integer)
  integer.times do |i|
    i * 2
  end
  integer.times do |i|
    i * 4
  end
end

def kernel_tap(x)
  i = 0
  while i < x
    x.tap do |y|
      y * 2
    end
    x.tap do |y|
      y * 4
    end
    i += 1
  end
end

def kernel_then(x)
  i = 0
  while i < x
    x.then do |y|
      y * 2
    end
    x.then do |y|
      y * 4
    end
    i += 1
  end
end

K = 100_000
ARRAY = (1..K).to_a

run_benchmark(1000) do
  i = 0
  while i < 10
    array_each(ARRAY)
    array_map(ARRAY)
    array_select(ARRAY)
    integer_times(K)
    kernel_tap(K)
    kernel_then(K)
    i += 1
  end
end
