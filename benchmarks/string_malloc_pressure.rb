require_relative '../harness/loader'

def build_string_malloc_pressure
  live = []
  500.times do
    live << Array.new(200) { String.new(capacity: 64 * 1024) }
  end
end

run_benchmark(10) do
  build_string_malloc_pressure
end
