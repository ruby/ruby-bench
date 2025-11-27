# Use harness/default.rb by default. You can change it with:
# 1. HARNESS environment variable (preferred, keeps harness close to code)
# 2. --harness option in run_once.rb
# 3. -r option when calling Ruby directly
#
# Examples:
#   HARNESS=perf ruby benchmarks/railsbench/benchmark.rb              # uses harness/perf.rb
#   HARNESS=once ruby benchmarks/railsbench/benchmark.rb              # uses harness/once.rb
#   ./run_once.rb --harness=ractor benchmarks/railsbench/benchmark.rb # uses harness/ractor.rb

# Only load the default harness if no other harness has defined run_benchmark
unless defined?(run_benchmark)
  harness_name = ENV['HARNESS'] || 'default'

  retries = 0
  begin
    require harness_name
  rescue LoadError => e
    if retries == 0 && e.path == harness_name
      retries += 1
      # Add the harness directory to the load path
      $LOAD_PATH << File.expand_path("../../harness", __dir__)
      retry
    end
    # Provide helpful error message for invalid harness
    if e.path == harness_name
      harness_dir = File.expand_path("../../harness", __dir__)
      available = Dir.glob("#{harness_dir}/*.rb").map { |f| File.basename(f, '.rb') }.sort
      raise LoadError, "Harness '#{harness_name}' not found. Available harnesses: #{available.join(', ')}"
    end
    raise
  end
end
