# frozen_string_literal: true

# Ensure a gem is installed globally (and add it to the load path)
# in a way that doesn't interfere with the benchmark's bundler setup.
def ensure_global_gem(name)
  found = Gem.find_latest_files(name).first
  unless found
    Gem.install(name)
    found = Gem.find_latest_files(name).first
  end
  warn "Adding to load path: #{File.dirname(found)}"
  $LOAD_PATH << File.dirname(found)
end

# Ensure an executable provided by the gem is present
# (useful for profile-viewer which has no lib, only the exe).
def ensure_global_gem_exe(name, exe = name)
  Gem.bin_path(name, exe)
rescue Gem::GemNotFoundException
  Gem.install(name)
end

# Call a gem exe, removing any bundler env vars that might confuse it.
def gem_exe(*args)
  system({'RUBYOPT' => '', 'BUNDLER_SETUP' => nil}, *args)
end

# Get benchmark base name from the file path.
def benchmark_name
  $0.match(%r{([^/]+?)(?:(?:/benchmark)?\.rb)?$})[1]
end

# Get name of harness (stackprof, vernier, etc) from the file path of the loaded harness.
def harness_name
  $LOADED_FEATURES.reverse_each do |feat|
    if m = feat.match(%r{/harness/([^/]+)\.rb$})
      return m[1]
    end
  end
  # Default to 'harness' if we can't determine the name
  'harness'
end

# Share a single timestamp for everything from this execution.
TIMESTAMP = Time.now.strftime('%F-%H%M%S')

# Create a consistent file path in the data directory
# so that the data can be further analyzed.
def output_file_path(prefix: harness_name, suffix: benchmark_name, ruby_info: ruby_version_info, timestamp: TIMESTAMP, ext: "bin")
  File.expand_path("../data/#{prefix}-#{timestamp}-#{ruby_info}-#{suffix}.#{ext}", __dir__)
end

# Can we get the benchmark config name from somewhere?
def ruby_version_info
  "#{RUBY_ENGINE}-#{RUBY_ENGINE_VERSION}"
end

def get_time
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

MIN_BENCH_TIME = Integer(ENV.fetch('MIN_BENCH_TIME', 10))

# Ensure the benchmark runs enough times for profilers to get sufficient data when sampling.
# Use the "n" hint (provided by the benchmarks themselves) as a starting point
# but allow that to be overridden by MIN_BENCH_ITRS env var.
# Also use MIN_BENCH_TIME to loop until the benchmark has run for a sufficient duration.
def run_enough_to_profile(n, &block)
  # Allow MIN_BENCH_ITRS to override the argument.
  n = ENV.fetch('MIN_BENCH_ITRS', n).to_i

  start = get_time
  loop do
    n.times(&block)

    break if (get_time - start) >= MIN_BENCH_TIME
  end
end
