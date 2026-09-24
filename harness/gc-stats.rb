# frozen_string_literal: true

# Shared, stateless GC sampling helpers.
#
# A "snapshot" is a fresh set of GC readings taken in the calling Ractor's
# object space (GC.stat, GC.stat_heap, and GC.total_time when supported).
# A "sample" is the delta between two snapshots bracketing a workload.
#
# Only a fixed whitelist of per-object-space scalars is differenced or summed.
# GC.stat may also contain process-global fields (e.g. page_pool_*) and
# identity values that must never be treated as per-worker workload counters.
module GCStats
  module_function

  # [sample field name, GC.stat key] pairs. Phase times are integer
  # milliseconds; sub-millisecond precision is only in gc_total_time_ns.
  SCALAR_FIELDS = [
    ["gc_count", :count],
    ["gc_major_count", :major_gc_count],
    ["gc_minor_count", :minor_gc_count],
    ["gc_marking_time", :marking_time],
    ["gc_sweeping_time", :sweeping_time],
  ].map(&:freeze).freeze

  TOTAL_TIME_FIELD = "gc_total_time_ns"

  # All scalar sample field names, including the nanosecond total.
  SCALAR_FIELD_NAMES = (SCALAR_FIELDS.map(&:first) + [TOTAL_TIME_FIELD]).freeze

  # Fresh GC.stat_heap hash, or {} when the platform lacks stat_heap.
  def heap_snapshot
    return {} unless GC.respond_to?(:stat_heap)
    GC.stat_heap
  end

  # Numeric per-heap, per-key differencing. Heaps or keys absent from the
  # before snapshot contribute nothing; gauge deltas may be negative.
  def heap_delta(before, after)
    delta = {}
    after.each do |heap_idx, after_stats|
      before_stats = before[heap_idx] || {}
      heap_delta = {}
      after_stats.each do |key, val|
        next unless val.is_a?(Numeric) && before_stats.key?(key)
        heap_delta[key] = val - before_stats[key]
      end
      delta[heap_idx] = heap_delta unless heap_delta.empty?
    end
    delta
  end

  # Fresh readings owned by this call; safe to keep without copying.
  def snapshot
    {
      stat: GC.stat(scope: :ractor),
      heap: heap_snapshot,
      total_time_ns: GC.respond_to?(:total_time) ? GC.total_time : nil,
    }
  end

  # Difference two snapshots. A scalar is nil unless both readings are
  # numeric; missing optional support never fabricates a zero.
  def delta(before, after)
    sample = {}
    SCALAR_FIELDS.each do |name, key|
      b = before[:stat][key]
      a = after[:stat][key]
      sample[name] = a.is_a?(Numeric) && b.is_a?(Numeric) ? a - b : nil
    end
    b_ns = before[:total_time_ns]
    a_ns = after[:total_time_ns]
    sample[TOTAL_TIME_FIELD] = a_ns.is_a?(Numeric) && b_ns.is_a?(Numeric) ? a_ns - b_ns : nil
    sample["gc_stat_heap_delta"] = heap_delta(before[:heap], after[:heap])
    sample["gc_heap_after"] = after[:heap]
    sample
  end

  # Run block.call(*args), bracketed by snapshots and a monotonic wall timer
  # around only the workload body. Enables GC total-time measurement for the
  # duration when supported, restoring the previous setting in ensure.
  # Workload or snapshot exceptions propagate unchanged; never calls GC.start.
  def measure(*args, &block)
    has_measure = GC.respond_to?(:measure_total_time) && GC.respond_to?(:measure_total_time=)
    saved = GC.measure_total_time if has_measure
    GC.measure_total_time = true if has_measure
    wall_time = nil
    begin
      before = snapshot
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      block.call(*args)
      wall_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      after = snapshot
    ensure
      # Whatever fails above — workload or either snapshot — the saved
      # setting is restored and the original exception propagates.
      GC.measure_total_time = saved if has_measure
    end
    sample = delta(before, after)
    sample["wall_time"] = wall_time
    sample
  end

  # Sum the whitelisted scalar fields across worker samples. A field is nil
  # if any sample lacks a numeric value. Heap maps and wall times are not
  # aggregated; controller samples must not be passed here.
  def aggregate(samples)
    raise ArgumentError, "Cannot aggregate an empty GC sample set" if samples.empty?
    SCALAR_FIELD_NAMES.each_with_object({}) do |name, result|
      values = samples.map { |s| s[name] }
      result[name] = values.all? { |v| v.is_a?(Numeric) } ? values.sum : nil
    end
  end
end
