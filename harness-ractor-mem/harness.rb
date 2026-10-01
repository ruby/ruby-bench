require_relative "../harness/harness-common"

Warning[:experimental] = false

default_ractors = [1, 2, 4, 6, 8]
if rs = ENV["RUBY_BENCH_RACTORS"]
  rs = rs.split(",").map(&:to_i)
  rs = rs.sort.uniq
  rs -= [0]
  ractors = rs unless rs.empty?
end
RACTORS = (ractors || default_ractors).freeze

MAX_ITERS = Integer(ENV.fetch("MAX_BENCH_ITRS", 3))
SETTLE_SLEEP = Float(ENV.fetch("RACTOR_MEM_SETTLE_SLEEP", 0.1))
PEAK_SAMPLE_INTERVAL = Float(ENV.fetch("RACTOR_MEM_PEAK_SAMPLE_INTERVAL", 0.005))

puts RUBY_DESCRIPTION

def gc_settle
  2.times { GC.start(full_mark: true, immediate_sweep: true) }
  sleep SETTLE_SLEEP
end

def statm_rss
  4096 * Integer(File.read("/proc/self/statm").split(" ")[1])
end

# Runs the given block while a background thread samples the process RSS.
# Returns the block result and the highest sampled RSS in bytes. Falls back to
# zero on platforms without /proc (peak reporting is a Linux-only extra).
def measure_peak_rss
  stop = false
  peak = 0
  sampler = Thread.new do
    Thread.current.report_on_exception = false
    until stop
      begin
        rss = statm_rss
        peak = rss if rss > peak
      rescue StandardError
        break
      end
      sleep PEAK_SAMPLE_INTERVAL
    end
  end
  result = yield
  stop = true
  sampler.join
  [result, peak]
end

# Memory-pathology harness for multiple ractors. Unlike harness-ractor, the
# scenario block runs on the main Ractor. It receives the ractor count and
# spawns its own ractors. It may return a cleanup proc, which the harness calls
# after measuring retained RSS (a scenario can park idling ractors that must
# outlive the measurement window).
def run_benchmark(num_itrs_hint, &scenario)
  bench_itrs = Integer(ENV.fetch("MIN_BENCH_ITRS", num_itrs_hint))
  bench_itrs = MAX_ITERS if bench_itrs > MAX_ITERS
  bench_itrs = 1 if bench_itrs < 1

  # The baseline is captured exactly once, before the first trial, and never
  # re-captured. Memory retained by dead or idle ractors is not returned to
  # the OS, but its pages are reused by later allocation, so a per-trial or
  # post-warmup baseline would absorb the retained pool and the measured
  # retention would collapse toward zero. Against the pristine baseline every
  # trial reports the size of the unreclaimed pool, which is stable across
  # trials and does not hide the pathology. This reuse behaviour was verified
  # on ruby 4.0.7 (2026-09-15).
  gc_settle
  base_rss = get_rss
  puts format("base RSS: %.1f MiB", base_rss / 2**20.0)

  metrics = Hash.new { |h, count| h[count] = { retained: [], peak: [] } }
  times = []

  RACTORS.each do |count|
    puts "ractors: #{count}"
    itr = 0
    while itr < bench_itrs
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      finish, peak = measure_peak_rss { scenario.call(count) }
      times << Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      gc_settle
      retained = get_rss - base_rss
      finish&.call
      gc_settle
      metrics[count][:retained] << retained
      metrics[count][:peak] << peak
      puts format("  itr #%d: retained %.1f MiB, peak %.1f MiB",
        itr + 1, retained / 2**20.0, peak / 2**20.0)
      itr += 1
    end
  end

  medians = {}
  RACTORS.each do |count|
    medians[count] = {
      retained: Stats.new(metrics[count][:retained]).median,
      peak: Stats.new(metrics[count][:peak]).median,
    }
  end
  worst_retained_count = medians.max_by { |_, m| m[:retained] }.first
  worst_retained = medians[worst_retained_count][:retained]
  worst_peak = medians.values.map { |m| m[:peak] }.max

  RACTORS.each do |count|
    m = medians[count]
    puts format("BENCH_METRIC retained_mib_r%d=%.1f", count, m[:retained] / 2**20.0)
    puts format("BENCH_METRIC peak_mib_r%d=%.1f", count, m[:peak] / 2**20.0)
  end
  puts format("BENCH_METRIC retained_mib=%.1f", worst_retained / 2**20.0)
  puts format("BENCH_METRIC peak_mib=%.1f", worst_peak / 2**20.0)
  puts format("BENCH_METRIC worst_ractor_count=%d", worst_retained_count)

  return_results([], times,
    ractor_mem_base_rss: base_rss,
    ractor_mem_medians: medians,
    ractor_mem_samples: metrics,
  )
end
