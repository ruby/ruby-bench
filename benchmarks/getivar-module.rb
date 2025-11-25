require_relative '../harness/loader'

class TheClass
  @v0 = 1
  @v1 = 2
  @v2 = 3
  @levar = 1

  def self.get_value_loop
    sum = 0

    # 1M
    i = 0
    while i < 1000000
      # 10 times to de-emphasize loop overhead
      sum += @levar
      sum += @levar
      sum += @levar
      sum += @levar
      sum += @levar
      sum += @levar
      sum += @levar
      sum += @levar
      sum += @levar
      sum += @levar
      i += 1
    end

    return sum
  end
end

module TheModule
  @v0 = 1
  @v1 = 2
  @v2 = 3
  @levar = 1

  def self.get_value_loop
    sum = 0

    # 1M
    i = 0
    while i < 1000000
      # 10 times to de-emphasize loop overhead
      sum += @levar
      sum += @levar
      sum += @levar
      sum += @levar
      sum += @levar
      sum += @levar
      sum += @levar
      sum += @levar
      sum += @levar
      sum += @levar
      i += 1
    end

    return sum
  end
end

run_benchmark(850) do
  TheClass.get_value_loop
  TheModule.get_value_loop
end
