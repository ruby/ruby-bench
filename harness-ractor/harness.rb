# frozen_string_literal: true
require_relative '../harness/harness-common'

Warning[:experimental] = false
ENV["RUBY_BENCH_RACTOR_HARNESS"] = "1"

# Opt-in Ractor-local GC metrics. Only the exact value "1" enables the mode.
RACTOR_GC_ENABLED = ENV["RUBY_BENCH_RACTOR_GC"] == "1"
require_relative '../harness/gc-stats' if RACTOR_GC_ENABLED

# Process-global GC counter support. GC.stat(key) raises ArgumentError for
# unknown keys on builds without it. This counter is process-wide, so it is
# measured as a controller-side per-iteration delta, never aggregated from
# per-worker samples.
HAS_GLOBAL_GC_COUNT = RACTOR_GC_ENABLED && begin
  GC.stat(:global_gc_count)
  true
rescue ArgumentError
  false
end

default_ractors = [
  0, # without ractor
  1, 2, 4, 6, 8#, 12, 16, 32
]
if rs = ENV["RUBY_BENCH_RACTORS"]
  rs = rs.split(",").map(&:to_i) # If you want to include 0, you have to specify
  rs = rs.sort.uniq
  if rs.any?
    ractors = rs
  end
end
RACTORS = (ractors || default_ractors).freeze

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

def run_benchmark(num_itrs_hint, ractor_args: [], &block)
  warmup_itrs = Integer(ENV.fetch('WARMUP_ITRS', 5))
  bench_itrs = Integer(ENV.fetch('MIN_BENCH_ITRS', num_itrs_hint))
  if bench_itrs > MAX_ITERS
    bench_itrs = MAX_ITERS
  end

  saved_measure_total_time = nil
  if RACTOR_GC_ENABLED
    # API prerequisites are checked before any warmup work so an unsupported
    # build fails immediately. These are API checks, not proof of
    # Ractor-local counter scope.
    unless GC.respond_to?(:total_time) && GC.respond_to?(:measure_total_time) && GC.respond_to?(:measure_total_time=)
      raise NotImplementedError, "Ractor GC metrics require GC.total_time and GC.measure_total_time="
    end
    # The main Ractor measures GC time for the whole run_benchmark call,
    # warmup included, restoring the saved setting even on failure.
    saved_measure_total_time = GC.measure_total_time
    GC.measure_total_time = true
  end

  begin
    # { num_ractors => [itr_in_ms, ...] }
    stats = Hash.new { |h,k| h[k] = [] }

    # GC mode prints its own extended header inside run_benchmark_gc.
    puts "r:   itr:   time" unless RACTOR_GC_ENABLED

    i = 0
    while i < warmup_itrs
      args = if ractor_args.empty?
        []
      else
        ractor_deep_dup(ractor_args)
      end
      block.call *([0] + args)
      i += 1
    end

    blk = Ractor.make_shareable(block)
    if RACTOR_GC_ENABLED
      return run_benchmark_gc(bench_itrs, blk, ractor_args)
    end
    RACTORS.each do |rs|
      num_itrs = 0
      while num_itrs < bench_itrs
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
        num_itrs += 1
        time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - before
        time_ms = (1000 * time).to_i
        itr_str = "%-3s %4s %6s" % ["#{rs}", "##{num_itrs}:", "#{time_ms}ms"]
        stats[rs] << time
        puts itr_str
      end
    end
    return_results([], stats.values.flatten, bench_by_ractors: stats)
  ensure
    GC.measure_total_time = saved_measure_total_time if RACTOR_GC_ENABLED
  end
end

# GC series name => GCStats.aggregate field. The total-time series is stored
# in milliseconds (float); all others keep their native integer units.
RACTOR_GC_SERIES = {
  "gc_count_bench" => "gc_count",
  "gc_major_count_bench" => "gc_major_count",
  "gc_minor_count_bench" => "gc_minor_count",
  "gc_marking_time_bench" => "gc_marking_time",
  "gc_sweeping_time_bench" => "gc_sweeping_time",
  "gc_total_time_bench" => "gc_total_time_ns",
}.freeze

# Ractor-local GC collection mode, selected by RUBY_BENCH_RACTOR_GC=1.
# Same warmup policy, worker counts, and iteration scheduling as the
# timing-only path; each measured iteration additionally samples GC in every
# worker's own object space. bench_by_ractors remains the lifecycle wall
# time from spawn through result receipt, including sampling overhead.
# API prerequisites were checked in run_benchmark before warmup.
def run_benchmark_gc(bench_itrs, block, ractor_args)
  stats = Hash.new { |h,k| h[k] = [] }
  gc_by_ractors = {}

  header = "r:   itr:   time   gc_total   marking  sweeping  gc_count     major     minor"
  header = "#{header}    global" if HAS_GLOBAL_GC_COUNT
  puts header

  RACTORS.each do |rs|
    group = { "gc_worker_samples" => [] }
    group["gc_controller_samples"] = [] if rs > 0
    series = Hash.new { |h,k| h[k] = [] }

    num_itrs = 0
    while num_itrs < bench_itrs
      num_itrs += 1
      elapsed, worker_samples, controller_sample, global_delta = run_ractor_gc_iteration(rs, ractor_args, &block)
      stats[rs] << elapsed
      group["gc_worker_samples"] << worker_samples
      group["gc_controller_samples"] << controller_sample if controller_sample

      agg = GCStats.aggregate(worker_samples)
      RACTOR_GC_SERIES.each do |series_name, field|
        value = agg[field]
        value = value / 1_000_000.0 if value && field == "gc_total_time_ns"
        series[series_name] << value
      end
      series["gc_global_count_bench"] << global_delta if HAS_GLOBAL_GC_COUNT

      fmt_ms = ->(v) { v.nil? ? "N/A" : ("%.1f" % v) }
      fmt_int = ->(v) { v.nil? ? "N/A" : v.to_s }
      itr_str = "%-3s %4s %6s" % [rs, "##{num_itrs}:", "#{(1000 * elapsed).to_i}ms"]
      itr_str << " %8s" % (agg["gc_total_time_ns"] ? "#{fmt_ms.call(agg["gc_total_time_ns"] / 1_000_000.0)}ms" : "N/A")
      itr_str << " %8s" % (agg["gc_marking_time"] ? "#{agg["gc_marking_time"]}ms" : "N/A")
      itr_str << " %8s" % (agg["gc_sweeping_time"] ? "#{agg["gc_sweeping_time"]}ms" : "N/A")
      itr_str << " %9s %9s %9s" % [fmt_int.call(agg["gc_count"]), fmt_int.call(agg["gc_major_count"]), fmt_int.call(agg["gc_minor_count"])]
      itr_str << " %9s" % fmt_int.call(global_delta) if HAS_GLOBAL_GC_COUNT
      puts itr_str
    end

    # Omit an optional series entirely if any iteration lacks a numeric
    # value; never drop a single entry and shift alignment.
    series.each do |name, values|
      group[name] = values unless values.any?(&:nil?)
    end
    gc_by_ractors[rs] = group
  end

  return_results([], stats.values.flatten,
    bench_by_ractors: stats,
    gc_scope: "ractor-local-workload",
    gc_by_ractors: gc_by_ractors)
end

# One measured GC-mode iteration. Returns
# [elapsed_seconds, worker_samples, controller_sample, global_gc_delta].
# worker_samples are ordered by zero-based spawn index; controller_sample is
# nil for count 0 so the main Ractor's workload sample is not counted twice.
# global_gc_delta is the process-wide GC.stat(:global_gc_count) delta across
# the whole iteration (spawn through join), or nil when unsupported; it is
# process-global and must never be summed across workers or counts.
def run_ractor_gc_iteration(num_ractors, ractor_args, &block)
  global_gc_before = GC.stat(:global_gc_count) if HAS_GLOBAL_GC_COUNT

  if num_ractors.zero?
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sample = GCStats.measure(0, *ractor_deep_dup(ractor_args), &block)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    sample["worker_index"] = 0
    global_gc_delta = GC.stat(:global_gc_count) - global_gc_before if HAS_GLOBAL_GC_COUNT
    return [elapsed, [sample], nil, global_gc_delta]
  end

  # Controller observations span worker creation through joining and are kept
  # separate from worker-workload totals.
  controller_before = GCStats.snapshot
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  pending = []
  num_ractors.times do |worker_index|
    # Explicit arguments only: no captured collector, method, or local state.
    pending << Ractor.new(worker_index, block, num_ractors, *ractor_args) do |index, workload, count, *args; sample|
      sample = GCStats.measure(count, *args, &workload)
      sample["worker_index"] = index
      sample
    end
  end

  samples = Array.new(num_ractors)
  while pending.any?
    ractor, sample = Ractor.select(*pending)
    pending.delete(ractor)
    samples[sample["worker_index"]] = sample
  end

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  controller_sample = GCStats.delta(controller_before, GCStats.snapshot)
  global_gc_delta = GC.stat(:global_gc_count) - global_gc_before if HAS_GLOBAL_GC_COUNT
  [elapsed, samples, controller_sample, global_gc_delta]
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
