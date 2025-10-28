# Use harness/harness.rb by default. You can change it with -I option.
# i.e. ruby -Iharness benchmarks/railsbench/benchmark.rb
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
