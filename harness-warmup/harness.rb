require 'benchmark'
require_relative '../harness/harness-common'
require_relative '../misc/stats'

MIN_ITERS = Integer(ENV['MIN_ITERS'] || 10)
MIN_TIME = Integer(ENV['MIN_TIME'] || 5)
MAX_TIME = Integer(ENV['MAX_TIME'] || 20 * 60)
MAD_TARGET = Float(ENV['MAD_TARGET'] || 0.001)
MAD_INCREASE_PER_ITER = Float(ENV['MAD_INCREASE_PER_ITER'] || 0.0001)

puts RUBY_DESCRIPTION

def ms(seconds)
  (1000 * seconds).to_i
end

def monotonic_time
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def print_stats(bench, elapsed)
  min, sec = elapsed.floor.divmod(60)
  puts "Benchmarking took #{min} minutes #{sec} seconds"
  puts "Statistics for the second half of iterations (considered warmed up):"
  stats = Stats.new(bench)
  median = stats.median
  mad = stats.median_absolute_deviation(median)
  mean, stddev = stats.mean, stats.stddev
  f2, f3 = '%.2f', '%.3f'
  puts "median: #{ms(median)}ms +/- #{f3 % (mad * 1000)}ms (#{f2 % (mad / median * 100)}%) (median absolute deviation)"
  puts "mean:   #{ms(mean)}ms +/- #{f3 % (stddev * 1000)}ms (#{f2 % (stddev / mean * 100)}%) (standard deviation)"
  puts "range: [#{ms(stats.min)}-#{ms(stats.max)}]ms"
end

# Takes a block as input
def run_benchmark(num_itrs_hint, **)
  start = monotonic_time
  times = []

  begin
    time = Benchmark.realtime { yield }
    times << time

    stats = Stats.new(times)
    median = stats.median
    mad = stats.median_absolute_deviation(median) / median
    extra_iters = times.size - MIN_ITERS
    threshold = extra_iters >= 0 ? MAD_TARGET + extra_iters * MAD_INCREASE_PER_ITER : 0.0

    puts "iter #%3d: %dms, mad=%.4f/%.4f, median=%dms" % [
      times.size,
      ms(time),
      mad,
      threshold,
      ms(median),
    ]

    elapsed = monotonic_time - start
    if elapsed >= MAX_TIME
      puts "timed out after #{(monotonic_time - start).to_i} seconds"
      break
    end
  end until times.size >= MIN_ITERS and elapsed >= MIN_TIME and mad <= threshold

  warmup, bench = times[0...times.size/2], times[times.size/2..-1]
  return_results(warmup, bench)

  print_stats(bench, elapsed)
end
