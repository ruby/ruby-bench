# A harness for Ruby implementations that compile the whole program ahead of
# time, such as Spinel (https://github.com/matz/spinel). harness/harness.rb
# relies on CRuby-only libraries and reflection (RubyVM, RbConfig, Fiddle,
# Bundler, $LOAD_PATH) that a whole-program compiler refuses to compile, so
# this file reimplements the same protocol in a portable subset of Ruby:
#
# * WARMUP_ITRS, MIN_BENCH_ITRS and MIN_BENCH_TIME select the iteration count.
# * RESULT_JSON_PATH receives the JSON that run_benchmarks.rb reads.
#
# harness/loader.rb selects this harness automatically when RUBY_ENGINE is
# "spinel", so `spinel -E benchmarks/fib.rb` works without any -I option. It
# also runs on CRuby (`ruby -Iharness-spinel benchmarks/fib.rb`), which is how
# its output is kept compatible with the default harness.
require "json"

# Warmup iterations
WARMUP_ITRS = Integer(ENV.fetch('WARMUP_ITRS', '15'))

# Minimum number of benchmarking iterations
MIN_BENCH_ITRS = Integer(ENV.fetch('MIN_BENCH_ITRS', '10'))

# Minimum benchmarking time in seconds
MIN_BENCH_TIME = Integer(ENV.fetch('MIN_BENCH_TIME', '10'))

# Do expand_path at require-time, not when returning results, before the benchmark is likely to chdir
default_path = File.expand_path("../data/results-#{RUBY_ENGINE}-#{RUBY_ENGINE_VERSION}-#{Time.now.strftime('%F-%H%M%S')}.json", __dir__)
YB_OUTPUT_FILE = File.expand_path(ENV.fetch("RESULT_JSON_PATH", default_path))

puts RUBY_DESCRIPTION

# Ractor.make_shareable is unavailable; benchmarks call this to share constants with Ractors.
def make_shareable(obj, copy: false)
  obj
end

def realtime
  r0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - r0
end

# This returns its best estimate of the Resident Set Size in bytes.
def get_rss
  mem_rollup_file = "/proc/#{Process.pid}/smaps_rollup"
  if File.exist?(mem_rollup_file)
    # Rss is always reported in kB by the Linux kernel, e.g. "Rss:   62796 kB"
    rss_line = File.read(mem_rollup_file).lines.find { |line| line.start_with?("Rss") }
    1024 * rss_line.split(":")[1].to_i
  else
    1024 * `ps -o rss= -p #{Process.pid}`.to_i
  end
end

# Takes a block as input
def run_benchmark(_num_itrs_hint, &block)
  times = []
  rss_samples = []
  total_time = 0.0
  num_itrs = 0

  puts "itr:   time"
  begin
    time = realtime(&block)
    num_itrs += 1

    time_ms = (1000 * time).to_i
    puts "%4s %6s" % ["##{num_itrs}:", "#{time_ms}ms"]

    # We internally save the time in seconds to avoid loss of precision
    times << time
    total_time += time
    # Sample current RSS between iterations (outside the timed block)
    rss_samples << get_rss
  end until num_itrs >= WARMUP_ITRS + MIN_BENCH_ITRS && total_time >= MIN_BENCH_TIME

  warmup = times[0...WARMUP_ITRS]
  bench = times[WARMUP_ITRS..-1]
  return_results(warmup, bench, rss_samples[WARMUP_ITRS..-1])

  if bench.size > 1
    bench_ms = ((bench.sum / bench.size) * 1000.0).to_i
    puts "Average of last #{bench.size}, non-warmup iters: #{bench_ms}ms"
  end
end

def return_results(warmup_iterations, bench_iterations, rss_samples)
  # Full GC before measuring RSS to lower GC variance.
  GC.start

  rss = get_rss
  ruby_bench_results = {
    "RUBY_DESCRIPTION" => RUBY_DESCRIPTION,
    "warmup" => warmup_iterations,
    "bench" => bench_iterations,
    "rss_samples" => rss_samples,
    "rss" => rss,
  }

  puts "RSS: %.1fMiB" % (rss / 1024.0 / 1024.0)

  out_path = YB_OUTPUT_FILE
  system('mkdir', '-p', File.dirname(out_path))

  # Using default path? Print where we put it.
  puts "Writing file #{out_path}" unless ENV["RESULT_JSON_PATH"]

  File.write(out_path, JSON.generate(ruby_bench_results))
end
