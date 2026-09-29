# frozen_string_literal: true
require_relative '../harness/harness-common'

Warning[:experimental] = false
ENV["RUBY_BENCH_RACTOR_HARNESS"] = "1"

RACTOR_GC_ENABLED = ENV["RUBY_BENCH_RACTOR_GC"] == "1"
require_relative '../lib/gc_stats' if RACTOR_GC_ENABLED

CONTROLLER_GC_SERIES = if RACTOR_GC_ENABLED
  {
    "gc_global_count_bench" => [:global_gc_count, "global*"],
    "gc_controller_compact_count_bench" => [:compact_count, "compacts*"],
  }.select { |_name, (stat_key, _label)| GCStats.stat_available?(stat_key) }
    .transform_values(&:freeze)
    .freeze
else
  {}.freeze
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
  bench_itrs = MAX_ITERS if bench_itrs > MAX_ITERS

  if RACTOR_GC_ENABLED
    check_ractor_gc_support
    gc_config = GC.config.transform_keys(&:to_s) if GC.respond_to?(:config)
    GCStats.with_measure_total_time do
      run_warmup(warmup_itrs, ractor_args, &block)
      run_benchmark_gc(bench_itrs, Ractor.make_shareable(block), ractor_args, gc_config: gc_config)
    end
  else
    puts "r:   itr:   time"
    run_warmup(warmup_itrs, ractor_args, &block)
    run_benchmark_timing(bench_itrs, ractor_args, &block)
  end
end

def check_ractor_gc_support
  unless GCStats.ractor_local_gc_supported?
    raise NotImplementedError, "Ractor GC metrics require Ruby 4.1 or newer"
  end
  unless GC.respond_to?(:total_time) && GC.respond_to?(:measure_total_time) && GC.respond_to?(:measure_total_time=)
    raise NotImplementedError, "Ractor GC metrics require GC.total_time and GC.measure_total_time="
  end
end

def run_warmup(warmup_itrs, ractor_args, &block)
  warmup_itrs.times do
    args = ractor_args.empty? ? [] : ractor_deep_dup(ractor_args)
    block.call(*([0] + args))
  end
end

def run_benchmark_timing(bench_itrs, ractor_args, &block)
  stats = Hash.new { |h,k| h[k] = [] }

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
end

RACTOR_GC_SERIES = {
  "gc_count_bench" => "gc_count",
  "gc_major_count_bench" => "gc_major_count",
  "gc_minor_count_bench" => "gc_minor_count",
  "gc_marking_time_bench" => "gc_marking_time",
  "gc_sweeping_time_bench" => "gc_sweeping_time",
  "gc_total_time_bench" => "gc_total_time_ns",
}.freeze

def run_benchmark_gc(bench_itrs, block, ractor_args, gc_config:)
  stats = Hash.new { |h,k| h[k] = [] }
  gc_by_ractors = {}

  header = +"r:   itr:   time   gc_total   marking  sweeping  gc_count     major     minor"
  CONTROLLER_GC_SERIES.each_value { |(_stat_key, label)| header << " %9s" % label }
  puts header
  puts "(* process/controller-observed; may overlap the other GC counts and is not additive.)" if CONTROLLER_GC_SERIES.any?

  RACTORS.each do |rs|
    group = { "gc_worker_samples" => [] }
    group["gc_controller_samples"] = [] if rs > 0
    series = Hash.new { |h,k| h[k] = [] }

    num_itrs = 0
    while num_itrs < bench_itrs
      num_itrs += 1
      elapsed, worker_samples, controller_sample, controller_deltas = run_ractor_gc_iteration(rs, ractor_args, &block)
      stats[rs] << elapsed
      group["gc_worker_samples"] << worker_samples
      group["gc_controller_samples"] << controller_sample if controller_sample

      agg = GCStats.aggregate(worker_samples)
      total_ms = agg["gc_total_time_ns"]&.fdiv(1_000_000)
      RACTOR_GC_SERIES.each do |series_name, field|
        series[series_name] << (field == "gc_total_time_ns" ? total_ms : agg[field])
      end
      CONTROLLER_GC_SERIES.each_key { |series_name| series[series_name] << controller_deltas[series_name] }

      itr_str = "%-3s %4s %6s" % [rs, "##{num_itrs}:", "#{(1000 * elapsed).to_i}ms"]
      itr_str << " %8s" % (total_ms ? "%.1fms" % total_ms : "N/A")
      itr_str << " %8s" % (agg["gc_marking_time"] ? "#{agg["gc_marking_time"]}ms" : "N/A")
      itr_str << " %8s" % (agg["gc_sweeping_time"] ? "#{agg["gc_sweeping_time"]}ms" : "N/A")
      itr_str << " %9s %9s %9s" % [agg["gc_count"], agg["gc_major_count"], agg["gc_minor_count"]].map { |v| v.nil? ? "N/A" : v.to_s }
      CONTROLLER_GC_SERIES.each_key { |series_name| itr_str << " %9s" % (controller_deltas[series_name] || "N/A") }
      puts itr_str
    end

    series.each do |name, values|
      group[name] = values
    end
    gc_by_ractors[rs] = group
  end

  extra = {
    bench_by_ractors: stats,
    gc_scope: "ractor-local-workload",
    gc_stat_scope: "ractor-local",
    gc_measure_total_time_scope: "ractor-local",
    gc_by_ractors: gc_by_ractors,
  }
  extra[:gc_config] = gc_config if gc_config
  return_results([], stats.values.flatten, **extra)
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
