require_relative '../harness/loader'

class C
  def ruby_func(call_block)
    # Don't even yield
    yield if call_block
  end
end

INSTANCE = C.new

run_benchmark(500) do
  500_000.times do |i|
    # Manually unrolling to avoid loop overhead
    INSTANCE.ruby_func(false) {}
    INSTANCE.ruby_func(false) {}
    INSTANCE.ruby_func(false) {}
    INSTANCE.ruby_func(false) {}
    INSTANCE.ruby_func(false) {}
    INSTANCE.ruby_func(false) {}
    INSTANCE.ruby_func(false) {}
    INSTANCE.ruby_func(false) {}
    INSTANCE.ruby_func(false) {}
  end
end
