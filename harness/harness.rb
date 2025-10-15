require_relative "./harness-common"

# Warmup iterations
WARMUP_ITRS = Integer(ENV.fetch('WARMUP_ITRS', 15))

# Minimum number of benchmarking iterations
MIN_BENCH_ITRS = Integer(ENV.fetch('MIN_BENCH_ITRS', 10))

# Minimum benchmarking time in seconds
MIN_BENCH_TIME = Integer(ENV.fetch('MIN_BENCH_TIME', 10))

default_path = "data/results-#{RUBY_ENGINE}-#{RUBY_ENGINE_VERSION}-#{Time.now.strftime('%F-%H%M%S')}.csv"
OUT_CSV_PATH = File.expand_path(ENV.fetch('OUT_CSV_PATH', default_path))

RSS_CSV_PATH = ENV['RSS_CSV_PATH'] ? File.expand_path(ENV['RSS_CSV_PATH']) : nil

system('mkdir', '-p', File.dirname(OUT_CSV_PATH))

# We could include other values in this result if more become relevant
# but for now all we want to know is if YJIT was enabled at runtime.
def yjit_enabled?
  RubyVM::YJIT.enabled? if defined?(RubyVM::YJIT)
end
ORIGINAL_YJIT_ENABLED = yjit_enabled?

puts RUBY_DESCRIPTION

def realtime
  r0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - r0
end

# Takes a block as input
def run_benchmark(_num_itrs_hint, **, &block)
  times = []
  total_time = 0
  num_itrs = 0
  header = "itr:   time"

  RubyVM::YJIT.reset_stats! if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?

  # If $YJIT_BENCH_STATS or $ZJIT_BENCH_STATS is given, print the diff of these stats at each iteration.
  if yjit_stats = ENV["YJIT_BENCH_STATS"]
    yjit_stats = yjit_stats.split(",").map(&:to_sym).map { |key| [key, RubyVM::YJIT.runtime_stats(key)] }.to_h
    yjit_stats.each_key { |key| header << " #{key}" }
  end
  if zjit_stats = ENV["ZJIT_BENCH_STATS"]
    zjit_stats = zjit_stats.split(",").map(&:to_sym).map { |key| [key, RubyVM::ZJIT.stats(key)] }.to_h
    zjit_stats.each_key { |key| header << " #{key}" }
  end

  puts header
  begin
    time = realtime(&block)
    num_itrs += 1

    # NOTE: we may want to avoid this as it could trigger GC?
    time_ms = (1000 * time).to_i
    itr_str = "%4s %6s" % ["##{num_itrs}:", "#{time_ms}ms"]

    yjit_stats&.each do |key, old_value|
      new_value = RubyVM::YJIT.runtime_stats(key)
      itr_str << " %#{key.size}s" % format_number(new_value - old_value)
      yjit_stats[key] = new_value
    end
    zjit_stats&.each do |key, old_value|
      new_value = RubyVM::ZJIT.stats(key)
      itr_str << " %#{key.size}s" % format_number(new_value - old_value)
      zjit_stats[key] = new_value
    end

    puts itr_str
    # NOTE: we may want to preallocate an array and avoid append
    # We internally save the time in seconds to avoid loss of precision
    times << time
    total_time += time
  end until num_itrs >= WARMUP_ITRS + MIN_BENCH_ITRS and total_time >= MIN_BENCH_TIME

  warmup, bench = times[0...WARMUP_ITRS], times[WARMUP_ITRS..-1]
  return_results(warmup, bench)

  non_warmups = times[WARMUP_ITRS..-1]
  if non_warmups.size > 1
    non_warmups_ms = ((non_warmups.sum / non_warmups.size) * 1000.0).to_i
    puts "Average of last #{non_warmups.size}, non-warmup iters: #{non_warmups_ms}ms"
  end

  if yjit_enabled? != ORIGINAL_YJIT_ENABLED
    raise "Benchmark altered YJIT configuration! (changed from #{ORIGINAL_YJIT_ENABLED.inspect} to #{yjit_enabled?.inspect})"
  end
end
