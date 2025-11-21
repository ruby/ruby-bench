require_relative '../lib/harness/loader'

TheClass = Struct.new(:v0, :v1, :v2, :levar)

def get_value_loop obj
  sum = 0
  # 1M
  i = 0
  while i < 1000000
    # 10 times to de-emphasize loop overhead
    sum += obj.levar
    sum += obj.levar
    sum += obj.levar
    sum += obj.levar
    sum += obj.levar
    sum += obj.levar
    sum += obj.levar
    sum += obj.levar
    sum += obj.levar
    sum += obj.levar
    i += 1
  end

  return sum
end

obj = TheClass.new(1, 2, 3, 1)

run_benchmark(850) do
  get_value_loop obj
end
