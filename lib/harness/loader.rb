# Use harness/default.rb by default. You can change it with the --harness option in run_once.rb
# or with -r option when calling Ruby directly.
# Examples:
#   ./run_once.rb benchmarks/railsbench/benchmark.rb                  # uses harness/default.rb
#   ./run_once.rb --harness=once benchmarks/railsbench/benchmark.rb   # uses harness/once.rb
#   ./run_once.rb --harness=ractor benchmarks/railsbench/benchmark.rb # uses harness/ractor.rb

# Only load the default harness if no other harness has defined run_benchmark
unless defined?(run_benchmark)
  retries = 0
  begin
    require "default"
  rescue LoadError => e
    if retries == 0 && e.path == "default"
      retries += 1
      # Add the harness directory to the load path
      $LOAD_PATH << File.expand_path("../../harness", __dir__)
      retry
    end
    raise
  end
end
