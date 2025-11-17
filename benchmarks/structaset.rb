require_relative '../harness/loader'

TheClass = Struct.new(:v0, :v1, :v2, :levar)

def set_value_loop obj
  # 1M
  i = 0
  while i < 1000000
    # 10 times to de-emphasize loop overhead
    obj.levar = i
    obj.levar = i
    obj.levar = i
    obj.levar = i
    obj.levar = i
    obj.levar = i
    obj.levar = i
    obj.levar = i
    obj.levar = i
    obj.levar = i
    i += 1
  end
end

obj = TheClass.new(1, 2, 3, 1)

run_benchmark(850) do
  set_value_loop obj
end
