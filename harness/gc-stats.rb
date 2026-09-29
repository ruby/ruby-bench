# frozen_string_literal: true

module GCStats
  module_function

  SCALAR_FIELDS = [
    ["gc_count", :count],
    ["gc_major_count", :major_gc_count],
    ["gc_minor_count", :minor_gc_count],
    ["gc_marking_time", :marking_time],
    ["gc_sweeping_time", :sweeping_time],
  ].map(&:freeze).freeze

  TOTAL_TIME_FIELD = "gc_total_time_ns"

  SCALAR_FIELD_NAMES = (SCALAR_FIELDS.map(&:first) + [TOTAL_TIME_FIELD]).freeze

  def stat_available?(key)
    GC.stat(key).is_a?(Numeric)
  rescue ArgumentError
    false
  end

  def heap_snapshot
    return {} unless GC.respond_to?(:stat_heap)
    GC.stat_heap
  end

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

  def snapshot
    {
      stat: GC.stat(scope: :ractor),
      heap: heap_snapshot,
      total_time_ns: GC.respond_to?(:total_time) ? GC.total_time : nil,
    }
  end

  def numeric_delta(before, after)
    after - before if before.is_a?(Numeric) && after.is_a?(Numeric)
  end

  def delta(before, after)
    sample = SCALAR_FIELDS.each_with_object({}) do |(name, key), result|
      result[name] = numeric_delta(before[:stat][key], after[:stat][key])
    end
    sample[TOTAL_TIME_FIELD] = numeric_delta(before[:total_time_ns], after[:total_time_ns])
    sample["gc_stat_heap_delta"] = heap_delta(before[:heap], after[:heap])
    sample["gc_heap_after"] = after[:heap]
    sample
  end
end
