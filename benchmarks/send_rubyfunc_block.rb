require_relative '../harness/loader'

class C
  def ruby_func
    # Don't even yield
  end
end

INSTANCE = C.new

run_benchmark(500) do
  500_000.times do |i|
    # Manually unrolling to avoid loop overhead
    INSTANCE.ruby_func {}
    INSTANCE.ruby_func {}
    INSTANCE.ruby_func {}
    INSTANCE.ruby_func {}
    INSTANCE.ruby_func {}
    INSTANCE.ruby_func {}
    INSTANCE.ruby_func {}
    INSTANCE.ruby_func {}
    INSTANCE.ruby_func {}
  end
end
