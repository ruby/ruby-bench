require_relative '../harness/loader'

class TheClass
  def initialize
    @v0 = 1
    @v1 = 2
    @v3 = 3
    @levar = 1
  end

  def set_value_loop
    # 1M
    i = 0
    while i < 1000000
      # 10 times to de-emphasize loop overhead
      @levar = i
      @levar = i
      @levar = i
      @levar = i
      @levar = i
      @levar = i
      @levar = i
      @levar = i
      @levar = i
      @levar = i
      i += 1
    end
  end
end

obj = TheClass.new

if ENV["YJIT_BENCH_RACTOR_HARNESS"]
  # same code as below, just pass obj as a ractor arg
  run_benchmark(1000, ractor_args: [obj]) do |_, object|
    object.set_value_loop
  end
else
  run_benchmark(1000) do
    obj.set_value_loop
  end
end
