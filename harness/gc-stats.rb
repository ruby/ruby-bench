# frozen_string_literal: true

module GCStats
  module_function

  SCALAR_FIELDS = [
    ["gc_count", :count],
    ["gc_global_count", :global_gc_count],
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

  def ractor_local_gc_supported?(version = RUBY_VERSION)
    major, minor = version.split(".").first(2).map(&:to_i)
    major > 4 || (major == 4 && minor >= 1)
  end

  def global_gc_attributed?
    return false unless Process.respond_to?(:fork)

    pid = fork do
      Warning[:experimental] = false
      $stderr.reopen(File::NULL, "w")
      begin
        main_before = GC.stat(:global_gc_count)
        process_before = GC.stat(:global_gc_count, scope: :global)
        Ractor.new { GC.start(full_mark: true, immediate_mark: true, immediate_sweep: true, global: true) }.join
        attributed = GC.stat(:global_gc_count) == main_before
        ran = GC.stat(:global_gc_count, scope: :global) > process_before
        exit!(attributed && ran ? 0 : 1)
      rescue StandardError
        exit!(2)
      end
    end
    _pid, status = Process.wait2(pid)
    status.success?
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

  def numeric_delta(before, after)
    after - before if before.is_a?(Numeric) && after.is_a?(Numeric)
  end

  def snapshot
    {
      stat: GC.stat(scope: :ractor),
      heap: heap_snapshot,
      total_time_ns: GC.respond_to?(:total_time) ? GC.total_time : nil,
    }
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

  def with_measure_total_time
    has_measure = GC.respond_to?(:measure_total_time) && GC.respond_to?(:measure_total_time=)
    saved = GC.measure_total_time if has_measure
    GC.measure_total_time = true if has_measure
    begin
      yield
    ensure
      GC.measure_total_time = saved if has_measure
    end
  end

  def measure(*args)
    with_measure_total_time do
      before = snapshot
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield(*args)
      wall_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      after = snapshot
      sample = delta(before, after)
      sample["wall_time"] = wall_time
      sample
    end
  end

  def aggregate(samples)
    raise ArgumentError, "Cannot aggregate an empty GC sample set" if samples.empty?
    SCALAR_FIELD_NAMES.each_with_object({}) do |name, result|
      values = samples.map { |s| s[name] }
      result[name] = values.all? { |v| v.is_a?(Numeric) } ? values.sum : nil
    end
  end
end
