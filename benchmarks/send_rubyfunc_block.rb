require_relative '../harness/loader'

class C
  def ruby_func
    # Don't even yield
  end
end

INSTANCE = C.new

run_benchmark(500) do
  2_000_000.times do |i|
    INSTANCE.ruby_func {}
  end
end
