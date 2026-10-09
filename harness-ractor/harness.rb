# frozen_string_literal: true
require_relative '../harness/harness-common'
require 'etc'

Warning[:experimental] = false
ENV["RUBY_BENCH_RACTOR_HARNESS"] = "1"

RACTOR_GC_ENABLED = ENV["RUBY_BENCH_RACTOR_GC"] == "1"
require_relative '../lib/gc_stats' if RACTOR_GC_ENABLED

CONTROLLER_GC_SERIES = if RACTOR_GC_ENABLED
  {
    "gc_controller_compact_count_bench" => [:compact_count, "compacts*"],
  }.select { |_name, (stat_key, _label)| GCStats.stat_available?(stat_key) }
    .transform_values(&:freeze)
    .freeze
else
  {}.freeze
end

require_relative '../lib/ractor_counts'
RACTORS = RactorCounts.from_env

unless Ractor.method_defined?(:join)
  class Ractor
    def join
      take
      self
    end
    alias value take
  end
end

MAX_ITERS = Integer(ENV.fetch("MAX_BENCH_ITRS", 5))
WORKER_GC_SAMPLES = []
SETTLE_SLEEP = Float(ENV.fetch("RACTOR_MEM_SETTLE_SLEEP", 0.1))
PEAK_SAMPLE_INTERVAL = Float(ENV.fetch("RACTOR_MEM_PEAK_SAMPLE_INTERVAL", 0.005))
GLOBAL_GC_START = GC.method(:start).parameters.include?([:key, :global])
PAGE_SIZE = Etc.sysconf(Etc::SC_PAGESIZE)

def run_benchmark(num_itrs_hint, ractor_args: [], scenario: false, &block)
  warmup_itrs = Integer(ENV.fetch('WARMUP_ITRS', 5))
  bench_itrs = Integer(ENV.fetch('MIN_BENCH_ITRS', num_itrs_hint))
  bench_itrs = MAX_ITERS if bench_itrs > MAX_ITERS
  raise ArgumentError, "a scenario benchmark does not take ractor_args" if scenario && !ractor_args.empty?

  if RACTOR_GC_ENABLED
    GCStats.check_ractor_gc_support!
    gc_config = GC.config.transform_keys(&:to_s) if GC.respond_to?(:config)
    GCStats.with_measure_total_time do
      if scenario
        run_scenario_benchmark(bench_itrs, gc_config: gc_config, &block)
      else
        run_benchmark_gc(warmup_itrs, bench_itrs, Ractor.make_shareable(block), ractor_args, gc_config: gc_config)
      end
    end
  elsif scenario
    run_scenario_benchmark(bench_itrs, gc_config: nil, &block)
  else
    puts "r:   itr:   time"
    run_benchmark_timing(warmup_itrs, bench_itrs, ractor_args, &block)
  end
end

def run_benchmark_timing(warmup_itrs, bench_itrs, ractor_args, &block)
  warmups = {}
  stats = {}

  RACTORS.each do |rs|
    times = Array.new(warmup_itrs + bench_itrs) do |i|
      time = run_timing_iteration(rs, ractor_args, &block)
      puts "%-3s %4s %6s" % ["#{rs}", "##{i + 1}:", "#{(1000 * time).to_i}ms"]
      time
    end
    warmups[rs], stats[rs] = times[0...warmup_itrs], times[warmup_itrs..]
  end
  return_results(warmups.values.flatten, stats.values.flatten, warmup_by_ractors: warmups, bench_by_ractors: stats)
end

def run_timing_iteration(rs, ractor_args, &block)
  before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  if rs.zero?
    block.call *([rs] + ractor_deep_dup(ractor_args))
  else
    rs_list = []
    rs.times do
      rs_list << Ractor.new(*([rs] + ractor_args), &block) # ractor_args are copied
    end
    while rs_list.any?
      r, _obj = Ractor.select(*rs_list)
      rs_list.delete(r)
    end
  end
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - before
end

def run_benchmark_gc(warmup_itrs, bench_itrs, block, ractor_args, gc_config:)
  warmups = {}
  stats = {}
  gc_by_ractors = {}

  print_gc_header("r:   itr:   time")

  RACTORS.each do |rs|
    warmups[rs] = []
    stats[rs] = []
    group = { "gc_worker_samples" => [] }
    group["gc_controller_samples"] = [] if rs > 0
    series = Hash.new { |h,k| h[k] = [] }

    (warmup_itrs + bench_itrs).times do |i|
      elapsed, worker_samples, controller_sample, controller_deltas = run_ractor_gc_iteration(rs, ractor_args, &block)
      agg = GCStats.aggregate(worker_samples)
      itr_str = "%-3s %4s %6s" % [rs, "##{i + 1}:", "#{(1000 * elapsed).to_i}ms"]
      puts itr_str + gc_columns(agg, controller_deltas)

      if i < warmup_itrs
        warmups[rs] << elapsed
        next
      end

      stats[rs] << elapsed
      group["gc_worker_samples"] << worker_samples
      group["gc_controller_samples"] << controller_sample if controller_sample
      record_gc_series(series, agg, controller_deltas)
    end

    series.each do |name, values|
      group[name] = values
    end
    gc_by_ractors[rs] = group
  end

  return_results(warmups.values.flatten, stats.values.flatten, warmup_by_ractors: warmups, bench_by_ractors: stats, **ractor_gc_results(gc_by_ractors, gc_config))
end

def print_gc_header(prefix)
  header = prefix + "   gc_total   marking  sweeping  gc_count     major     minor    global"
  CONTROLLER_GC_SERIES.each_value { |(_stat_key, label)| header << " %9s" % label }
  puts header
  puts "(* controller-observed compacting cycles; may overlap global counts and is not additive.)" if CONTROLLER_GC_SERIES.any?
end

def record_gc_series(series, agg, controller_deltas)
  GCStats::RACTOR_SERIES.each do |series_name, field|
    series[series_name] << (field == GCStats::TOTAL_TIME_FIELD ? agg[field]&.fdiv(1_000_000) : agg[field])
  end
  CONTROLLER_GC_SERIES.each_key { |series_name| series[series_name] << controller_deltas[series_name] }
end

def gc_columns(agg, controller_deltas)
  total_ms = agg[GCStats::TOTAL_TIME_FIELD]&.fdiv(1_000_000)
  columns = " %8s" % (total_ms ? "%.1fms" % total_ms : "N/A")
  columns << " %8s" % (agg["gc_marking_time"] ? "#{agg["gc_marking_time"]}ms" : "N/A")
  columns << " %8s" % (agg["gc_sweeping_time"] ? "#{agg["gc_sweeping_time"]}ms" : "N/A")
  columns << " %9s %9s %9s %9s" % [agg["gc_count"], agg["gc_major_count"], agg["gc_minor_count"], agg["gc_global_count"]].map { |v| v.nil? ? "N/A" : v.to_s }
  CONTROLLER_GC_SERIES.each_key { |series_name| columns << " %9s" % (controller_deltas[series_name] || "N/A") }
  columns
end

def ractor_gc_results(gc_by_ractors, gc_config)
  extra = {
    gc_scope: "ractor-local-workload",
    gc_stat_scope: "ractor-local",
    gc_measure_total_time_scope: "ractor-local",
    gc_by_ractors: gc_by_ractors,
  }
  extra[:gc_config] = gc_config if gc_config
  extra
end

def controller_gc_snapshot
  CONTROLLER_GC_SERIES.transform_values { |(stat_key, _label)| GC.stat(stat_key) }
end

def controller_gc_deltas(before, after)
  before.each_with_object({}) do |(series_name, before_value), deltas|
    after_value = after[series_name]
    deltas[series_name] = after_value - before_value if before_value.is_a?(Numeric) && after_value.is_a?(Numeric)
  end
end

def run_ractor_gc_iteration(num_ractors, ractor_args, &block)
  return run_controller_gc_iteration(ractor_args, &block) if num_ractors.zero?

  controller_before = GCStats.snapshot
  counters_before = controller_gc_snapshot
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  pending = []
  num_ractors.times do |worker_index|
    pending << Ractor.new(worker_index, block, num_ractors, *ractor_args) do |index, workload, count, *args|
      sample = GCStats.measure(count, *args, &workload)
      sample["worker_index"] = index
      sample
    end
  end

  samples = Array.new(num_ractors)
  while pending.any?
    ractor, worker_sample = Ractor.select(*pending)
    pending.delete(ractor)
    samples[worker_sample["worker_index"]] = worker_sample
  end

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  counters_after = controller_gc_snapshot
  controller_sample = GCStats.delta(controller_before, GCStats.snapshot)
  [elapsed, samples, controller_sample, controller_gc_deltas(counters_before, counters_after)]
end

def run_controller_gc_iteration(ractor_args, &block)
  counters_before = controller_gc_snapshot
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  sample = GCStats.measure(0, *ractor_deep_dup(ractor_args), &block)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  counters_after = controller_gc_snapshot
  sample["worker_index"] = 0
  [elapsed, [sample], nil, controller_gc_deltas(counters_before, counters_after)]
end

def measure_worker_gc
  return [yield, nil] unless RACTOR_GC_ENABLED

  result = nil
  sample = GCStats.measure { result = yield }
  [result, sample]
end

def record_worker_gc(worker_index, sample)
  return unless sample

  WORKER_GC_SAMPLES << sample.merge("worker_index" => worker_index)
end

def run_scenario_benchmark(bench_itrs, gc_config:, &scenario)
  counts = RACTORS - [0]
  raise ArgumentError, "a scenario benchmark needs a Ractor count above 0" if counts.empty?
  bench_itrs = 1 if bench_itrs < 1

  gc_settle
  base_rss = get_rss
  puts "base RSS: #{format_mib(base_rss)}"
  puts "malloc_trim unavailable, retained RSS includes allocator caching: #{MallocTrim.error}" if MallocTrim.error
  header = "r:   itr:   time" + " %9s %9s" % ["retained", "peak"]
  RACTOR_GC_ENABLED ? print_gc_header(header) : puts(header)

  times = Hash.new { |h, k| h[k] = [] }
  memory = Hash.new { |h, k| h[k] = { retained: [], peak: [] } }
  gc_by_ractors = {}

  counts.each do |count|
    group = { "gc_worker_samples" => [], "gc_controller_samples" => [] }
    series = Hash.new { |h, k| h[k] = [] }

    bench_itrs.times do |itr|
      elapsed, finish, peak, gc = run_scenario_iteration(count, &scenario)
      gc_settle
      retained = get_rss - base_rss
      finish&.call
      gc_settle

      times[count] << elapsed
      memory[count][:retained] << retained
      memory[count][:peak] << peak
      itr_str = "%-3s %4s %6s %9s %9s" % [count, "##{itr + 1}:", "#{(1000 * elapsed).to_i}ms", format_mib(retained), format_mib(peak)]
      if gc
        group["gc_worker_samples"] << gc[:workers]
        group["gc_controller_samples"] << gc[:controller]
        agg = GCStats.aggregate(gc[:workers])
        record_gc_series(series, agg, gc[:deltas])
        itr_str << gc_columns(agg, gc[:deltas])
      end
      puts itr_str
    end

    gc_by_ractors[count] = group.merge(series)
  end

  medians = counts.to_h { |count| [count, memory_summary(memory[count])] }
  print_memory_metrics(medians)

  extra = {
    warmup_by_ractors: counts.to_h { |count| [count, []] },
    bench_by_ractors: times,
    ractor_mode: "scenario",
    ractor_mem_settle: GLOBAL_GC_START ? "global" : "default",
    ractor_mem_malloc_trim: MallocTrim.available?,
    ractor_mem_base_rss: base_rss,
    ractor_mem_medians: medians,
    ractor_mem_samples: memory,
  }
  extra.merge!(ractor_gc_results(gc_by_ractors, gc_config)) if RACTOR_GC_ENABLED
  return_results([], times.values.flatten, **extra)
end

def run_scenario_iteration(count, &scenario)
  WORKER_GC_SAMPLES.clear
  if RACTOR_GC_ENABLED
    controller_before = GCStats.snapshot
    counters_before = controller_gc_snapshot
  end
  (finish, elapsed), peak = measure_peak_rss do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = scenario.call(count)
    [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end
  return [elapsed, finish, peak, nil] unless RACTOR_GC_ENABLED

  counters_after = controller_gc_snapshot
  gc = {
    controller: GCStats.delta(controller_before, GCStats.snapshot),
    deltas: controller_gc_deltas(counters_before, counters_after),
    workers: scenario_worker_samples(count),
  }
  [elapsed, finish, peak, gc]
end

def scenario_worker_samples(count)
  workers = WORKER_GC_SAMPLES.sort_by { |sample| sample["worker_index"] }
  indexes = workers.map { |sample| sample["worker_index"] }
  raise "scenario recorded worker GC samples #{indexes.inspect} for #{count} ractors" unless indexes == (0...count).to_a
  workers
end

# glibc's free() only returns memory to the OS by shrinking the top of the heap,
# so memory a scenario malloc'd and Ruby has since freed (Ractor message copies,
# for example) stays resident whenever a live chunk sits above it. Ruby's GC does
# not trim, so without this retained RSS measures glibc's caching, not Ruby.
# Memoized on a module, not on main: the Ractor harness freezes main.
module MallocTrim
  @resolved = false

  # The malloc_trim function, or nil when libc does not have one (macOS, musl,
  # or a Ruby built against another allocator that leaves glibc's unused).
  def self.fn
    return @fn if @resolved

    @resolved = true
    @fn = begin
      load_fiddle
      Fiddle::Function.new(Fiddle.dlopen(nil)['malloc_trim'], [Fiddle::TYPE_SIZE_T], Fiddle::TYPE_INT)
    rescue LoadError, Fiddle::DLError, NameError => e
      @error = "#{e.class}: #{e.message}"
      nil
    end
  end

  # Why the lookup failed, or nil when it succeeded or has not run yet.
  def self.error
    @error
  end

  def self.available?
    !fn.nil?
  end

  def self.call
    fn&.call(0)
  end
end

def gc_settle
  2.times do
    if GLOBAL_GC_START
      GC.start(full_mark: true, immediate_sweep: true, global: true)
    else
      GC.start(full_mark: true, immediate_sweep: true)
    end
  end
  MallocTrim.call
  sleep SETTLE_SLEEP
end

STATM_FILE = "/proc/self/statm"
STATM_AVAILABLE = File.exist?(STATM_FILE)

# The resident set size right now. /proc/self/statm is the cheapest source, which
# matters because the peak sampler reads it every PEAK_SAMPLE_INTERVAL. Off Linux
# it does not exist, so fall back to get_rss, which shells out to ps.
def statm_rss
  return get_rss unless STATM_AVAILABLE

  PAGE_SIZE * Integer(File.read(STATM_FILE).split(" ")[1])
end

def measure_peak_rss
  stop = false
  peak = statm_rss
  sampler = Thread.new do
    Thread.current.report_on_exception = false
    until stop
      rss = statm_rss
      peak = rss if rss > peak
      sleep PEAK_SAMPLE_INTERVAL
    end
  end
  begin
    result = yield
  ensure
    stop = true
    sampler.join
  end
  [result, [peak, statm_rss].max]
end

def format_mib(bytes)
  "%.1fMiB" % (bytes / 2**20.0)
end

# Summarizes one count's per-trial samples. The median keys stay at their
# original names so existing readers keep working, with the mean and the
# largest of the same samples next to them; the peak table column reports the
# largest. No dispersion measure: retained RSS drifts upward across a count's
# trials by construction, so spread here is not noise.
def memory_summary(samples)
  samples.each_with_object({}) do |(metric, values), summary|
    stats = Stats.new(values)
    # Bytes. An even-trial median and every mean come back Float; round them,
    # since a fraction of a byte is not a measurement.
    summary[metric] = stats.median.round
    summary[:"#{metric}_mean"] = stats.mean.round
    summary[:"#{metric}_max"] = values.max
  end
end

def print_memory_metrics(medians)
  medians.each do |count, m|
    puts format("BENCH_METRIC retained_mib_r%d=%.1f", count, m[:retained] / 2**20.0)
    puts format("BENCH_METRIC peak_mib_r%d=%.1f", count, m[:peak] / 2**20.0)
  end
  worst_count, worst = medians.max_by { |_count, m| m[:retained] }
  puts format("BENCH_METRIC retained_mib=%.1f", worst[:retained] / 2**20.0)
  puts format("BENCH_METRIC peak_mib=%.1f", medians.values.map { |m| m[:peak] }.max / 2**20.0)
  puts format("BENCH_METRIC worst_ractor_count=%d", worst_count)
end

# NOTE: we use `ractor_deep_dup` instead of `Ractor.make_shareable(copy: true)` for the case of
# sending args to the block without a ractor because the arguments passed to `run_benchmark` are
# sometimes modified, and we want to allow that because it improves compatibility. We don't want
# it to be deeply frozen.
def ractor_deep_dup(args)
  if Array === args
    ret = []
    args.each do |el|
      ret << ractor_deep_dup(el)
    end
    ret
  elsif Hash === args
    ret = {}
    args.each do |k,v|
      ret[ractor_deep_dup(k)] = ractor_deep_dup(v)
    end
    ret
  else
    args.dup
  end
end

Ractor.make_shareable(self) # until we get Ractor.shareable_proc
