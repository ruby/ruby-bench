require_relative '../harness/loader'

class TheClass
  attr_accessor :levar

  def initialize
    @v0 = 1
    @v1 = 2
    @v2 = 3
    @levar = 1
  end

  def get_value_loop
    sum = 0

    # 1M
    i = 0
    while i < 1000000
      # 10 times to de-emphasize loop overhead
      sum += levar
      sum += levar
      sum += levar
      sum += levar
      sum += levar
      sum += levar
      sum += levar
      sum += levar
      sum += levar
      sum += levar
      i += 1
    end

    return sum
  end
end

OBJ = TheClass.new
Ractor.make_shareable(OBJ)

run_benchmark(10) do
  OBJ.get_value_loop
end
