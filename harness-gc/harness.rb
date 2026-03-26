require_relative "../harness/harness-common"

WARMUP_ITRS = Integer(ENV.fetch('WARMUP_ITRS', 15))
MIN_BENCH_ITRS = Integer(ENV.fetch('MIN_BENCH_ITRS', 10))
MIN_BENCH_TIME = Integer(ENV.fetch('MIN_BENCH_TIME', 10))

puts RUBY_DESCRIPTION

def realtime
  r0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - r0
end

def gc_stat_heap_snapshot
  return {} unless GC.respond_to?(:stat_heap)
  GC.stat_heap
end

def gc_stat_heap_delta(before, after)
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

def run_benchmark(_num_itrs_hint, **, &block)
  times = []
  marking_times = []
  sweeping_times = []
  gc_counts = []
  major_counts = []
  minor_counts = []
  gc_heap_deltas = []
  total_time = 0
  num_itrs = 0

  has_marking = GC.stat.key?(:marking_time)
  has_sweeping = GC.stat.key?(:sweeping_time)

  header = "itr:   time"
  header << "   marking" if has_marking
  header << "  sweeping" if has_sweeping
  header << "  gc_count"
  header << "     major"
  header << "     minor"
  header << "  maj/min"
  puts header

  begin
    gc_before = GC.stat
    heap_before = gc_stat_heap_snapshot

    time = realtime(&block)
    num_itrs += 1

    gc_after = GC.stat
    heap_after = gc_stat_heap_snapshot

    time_ms = (1000 * time).to_i
    mark_delta = has_marking ? gc_after[:marking_time] - gc_before[:marking_time] : 0
    sweep_delta = has_sweeping ? gc_after[:sweeping_time] - gc_before[:sweeping_time] : 0
    count_delta = gc_after[:count] - gc_before[:count]
    major_delta = gc_after[:major_gc_count] - gc_before[:major_gc_count]
    minor_delta = gc_after[:minor_gc_count] - gc_before[:minor_gc_count]
    ratio_str = minor_delta > 0 ? "%.2f" % (major_delta.to_f / minor_delta) : "-"

    itr_str = "%4s %6s" % ["##{num_itrs}:", "#{time_ms}ms"]
    itr_str << "%8.1fms" % mark_delta if has_marking
    itr_str << "%8.1fms" % sweep_delta if has_sweeping
    itr_str << " %9d" % count_delta
    itr_str << " %9d" % major_delta
    itr_str << " %9d" % minor_delta
    itr_str << "%9s" % ratio_str
    puts itr_str

    times << time
    marking_times << mark_delta
    sweeping_times << sweep_delta
    gc_counts << count_delta
    major_counts << major_delta
    minor_counts << minor_delta
    gc_heap_deltas << gc_stat_heap_delta(heap_before, heap_after)
    total_time += time
  end until num_itrs >= WARMUP_ITRS + MIN_BENCH_ITRS and total_time >= MIN_BENCH_TIME

  warmup_range = 0...WARMUP_ITRS
  bench_range = WARMUP_ITRS..-1

  extra = {}
  extra["gc_marking_time_warmup"] = marking_times[warmup_range]
  extra["gc_marking_time_bench"] = marking_times[bench_range]
  extra["gc_sweeping_time_warmup"] = sweeping_times[warmup_range]
  extra["gc_sweeping_time_bench"] = sweeping_times[bench_range]
  extra["gc_count_warmup"] = gc_counts[warmup_range]
  extra["gc_count_bench"] = gc_counts[bench_range]
  extra["gc_major_count_warmup"] = major_counts[warmup_range]
  extra["gc_major_count_bench"] = major_counts[bench_range]
  extra["gc_minor_count_warmup"] = minor_counts[warmup_range]
  extra["gc_minor_count_bench"] = minor_counts[bench_range]
  extra["gc_stat_heap_deltas"] = gc_heap_deltas[bench_range]

  # Snapshot heap utilisation after benchmark
  if GC.respond_to?(:stat_heap)
    GC.start(full_mark: true)
    heap_snapshot = GC.stat_heap
    extra["gc_heap_final"] = heap_snapshot.transform_values { |v| v.is_a?(Hash) ? v.dup : v }
  end

  return_results(times[warmup_range], times[bench_range], **extra)

  non_warmups = times[bench_range]
  if non_warmups.size > 1
    non_warmups_ms = ((non_warmups.sum / non_warmups.size) * 1000.0).to_i
    puts "Average of last #{non_warmups.size}, non-warmup iters: #{non_warmups_ms}ms"

    if has_marking
      mark_bench = marking_times[bench_range]
      avg_mark = mark_bench.sum / mark_bench.size
      puts "Average marking time: %.1fms" % avg_mark
    end

    if has_sweeping
      sweep_bench = sweeping_times[bench_range]
      avg_sweep = sweep_bench.sum / sweep_bench.size
      puts "Average sweeping time: %.1fms" % avg_sweep
    end
  end

  # Print heap utilisation table
  if heap_snapshot
    page_size = defined?(GC::INTERNAL_CONSTANTS) ? GC::INTERNAL_CONSTANTS[:HEAP_PAGE_SIZE] : nil

    puts "\nHeap utilisation (after full GC):"
    header = "heap  slot_size  eden_slots  live_slots  free_slots  eden_pages  live_pct  mem_KiB"
    puts header

    heap_snapshot.each do |idx, stats|
      slot_size = stats[:slot_size] || 0
      eden_slots = stats[:heap_eden_slots] || 0
      live_slots = stats[:heap_live_slots] || 0
      free_slots = stats[:heap_free_slots] || 0
      eden_pages = stats[:heap_eden_pages] || 0
      live_pct = eden_slots > 0 ? (live_slots * 100.0 / eden_slots) : 0.0
      mem_kib = page_size ? (eden_pages * page_size / 1024.0) : 0.0

      puts "%4d  %9d  %10d  %10d  %10d  %11d  %7.1f%%  %7.1f" % [
        idx, slot_size, eden_slots, live_slots, free_slots, eden_pages, live_pct, mem_kib
      ]
    end
  end
end
