require_relative '../lib/harness/loader'

run_benchmark(100) do
  i = 0
  while i < 1_000_000
    Object.new
    i += 1
  end
end
