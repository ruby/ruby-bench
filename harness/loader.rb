# Use harness/harness.rb by default. You can change it with -I and -r options.
# Examples:
#   ruby -Iharness benchmarks/railsbench/benchmark.rb           # uses harness/harness.rb
#   ruby -Iharness -ronce benchmarks/railsbench/benchmark.rb    # uses harness/once.rb
#   ruby -Iharness -rractor benchmarks/railsbench/benchmark.rb  # uses harness/ractor.rb
retries = 0
begin
  require "harness"
rescue LoadError => e
  if retries == 0 && e.path == "harness"
    retries += 1
    $LOAD_PATH << File.expand_path(__dir__)
    retry
  end
  raise
end
