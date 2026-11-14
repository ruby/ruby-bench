require_relative 'test_helper'
require_relative '../lib/gc_stats'

describe GCStats do
  def snapshot(count:, major:, minor:, marking: nil, sweeping: nil, total_ns: nil, heap: {})
    stat = { count: count, major_gc_count: major, minor_gc_count: minor }
    stat[:marking_time] = marking unless marking.nil?
    stat[:sweeping_time] = sweeping unless sweeping.nil?
    { stat: stat, heap: heap, total_time_ns: total_ns }
  end

  describe '.delta' do
    it 'subtracts before from after instead of reporting final counter values' do
      before = snapshot(count: 100, major: 10, minor: 90, marking: 40, sweeping: 60, total_ns: 5_000_000)
      after = snapshot(count: 107, major: 11, minor: 96, marking: 43, sweeping: 62, total_ns: 6_500_000)

      sample = GCStats.delta(before, after)

      assert_equal 7, sample['gc_count']
      assert_equal 1, sample['gc_major_count']
      assert_equal 6, sample['gc_minor_count']
      assert_equal 3, sample['gc_marking_time']
      assert_equal 2, sample['gc_sweeping_time']
      assert_equal 1_500_000, sample['gc_total_time_ns']
    end

    it 'returns nil for a field missing from either snapshot rather than a fake zero' do
      before = snapshot(count: 1, major: 1, minor: 0)
      after = snapshot(count: 3, major: 1, minor: 2, marking: 5)

      sample = GCStats.delta(before, after)

      assert_equal 2, sample['gc_count']
      assert_nil sample['gc_marking_time']
      assert_nil sample['gc_sweeping_time']
      assert_nil sample['gc_total_time_ns']
    end

    it 'keeps a supported zero delta as numeric zero, distinct from unavailable data' do
      before = snapshot(count: 5, major: 1, minor: 4, marking: 9, total_ns: 1_000)
      after = snapshot(count: 5, major: 1, minor: 4, marking: 9, total_ns: 1_000)

      sample = GCStats.delta(before, after)

      assert_equal 0, sample['gc_count']
      assert_equal 0, sample['gc_marking_time']
      assert_equal 0, sample['gc_total_time_ns']
    end

    it 'preserves sub-millisecond precision in the nanosecond total' do
      before = snapshot(count: 0, major: 0, minor: 0, total_ns: 1_000_000)
      after = snapshot(count: 1, major: 0, minor: 1, total_ns: 1_250_000)

      assert_equal 250_000, GCStats.delta(before, after)['gc_total_time_ns']
    end

    it 'counts only the global GCs that this Ractor started' do
      before = snapshot(count: 10, major: 2, minor: 5)
      before[:stat].merge!(global_gc_count: 3, global_gc_invocation_count: 1)
      after = snapshot(count: 16, major: 2, minor: 6)
      after[:stat].merge!(global_gc_count: 8, global_gc_invocation_count: 2)

      sample = GCStats.delta(before, after)

      assert_equal 2, sample['gc_count']
      assert_equal 1, sample['gc_global_count']
      assert_equal sample['gc_major_count'] + sample['gc_minor_count'] + sample['gc_global_count'], sample['gc_count']
    end

    it 'keeps heap gauge deltas signed and omits heaps/keys absent from the before snapshot' do
      before = snapshot(count: 0, major: 0, minor: 0, heap: {
        0 => { slot_size: 40, heap_eden_slots: 100, heap_live_slots: 50 }
      })
      after = snapshot(count: 0, major: 0, minor: 0, heap: {
        0 => { slot_size: 40, heap_eden_slots: 120, heap_live_slots: 40, heap_final_slots: 3 },
        1 => { slot_size: 80, heap_eden_slots: 10 }
      })

      heap_delta = GCStats.delta(before, after)['gc_stat_heap_delta']

      assert_equal 20, heap_delta[0][:heap_eden_slots]
      assert_equal(-10, heap_delta[0][:heap_live_slots])
      refute heap_delta[0].key?(:heap_final_slots), 'keys missing from before must not appear'
      refute heap_delta.key?(1), 'heaps missing from before must not appear'
    end

    it 'does not difference non-whitelisted stat keys such as process-global counters' do
      before = snapshot(count: 0, major: 0, minor: 0)
      before[:stat][:page_pool_total_pages] = 100
      before[:stat][:heap_allocatable_pages] = 7
      after = snapshot(count: 1, major: 0, minor: 1)
      after[:stat][:page_pool_total_pages] = 250
      after[:stat][:heap_allocatable_pages] = 9

      sample = GCStats.delta(before, after)

      refute sample.key?('page_pool_total_pages')
      refute sample.key?(:page_pool_total_pages)
      refute sample.key?('heap_allocatable_pages')
      assert_equal GCStats::SCALAR_FIELD_NAMES + %w[gc_stat_heap_delta gc_heap_after], sample.keys
    end

    it 'exposes the after-heap snapshot without copying it into the delta' do
      before = snapshot(count: 0, major: 0, minor: 0)
      after = snapshot(count: 0, major: 0, minor: 0, heap: { 0 => { slot_size: 40 } })

      sample = GCStats.delta(before, after)

      assert_same after[:heap], sample['gc_heap_after']
    end
  end

  describe '.marking_times_since' do
    def record(seq, major, mark)
      { GC_SEQUENCE: seq, GC_FLAGS: { major_by: major }, GC_MARK_WALL_TIME: mark }
    end

    it 'splits the marking time of each new collection into minor and major' do
      records = [record(5, nil, 0.001), record(6, :oldgen, 0.020), record(7, nil, 0.003)]

      minor, major, seq = GCStats.marking_times_since(4, records: records, marking: false)

      assert_equal [1.0, 3.0], minor.map { |ms| ms.round(6) }
      assert_equal [20.0], major.map { |ms| ms.round(6) }
      assert_equal 7, seq
    end

    it 'leaves a collection that is still marking for the next call' do
      records = [record(5, nil, 0.001), record(6, :nofree, 0.004)]

      minor, major, seq = GCStats.marking_times_since(4, records: records, marking: true)

      assert_equal [1.0], minor.map { |ms| ms.round(6) }
      assert_equal [], major
      assert_equal 5, seq
    end

    it 'reports nothing rather than a partial list when records were dropped' do
      minor, major, seq = GCStats.marking_times_since(4, records: [record(9, nil, 0.001)], marking: false)

      assert_nil minor
      assert_nil major
      assert_equal 9, seq
    end

    it 'takes every record on the first call, whatever its sequence number' do
      minor, _major, seq = GCStats.marking_times_since(nil, records: [record(9, nil, 0.002)], marking: false)

      assert_equal [2.0], minor.map { |ms| ms.round(6) }
      assert_equal 9, seq
    end

    it 'splits real minor and major collections' do
      skip 'GC::Profiler.raw_data(since:) is new in Ruby 4.1' unless GCStats.collection_records_supported?

      was_enabled = GC::Profiler.enabled?
      GC::Profiler.enable
      # A pending major (GC.latest_gc_info(:need_major_by)) would turn the minor into a major.
      GC.start(full_mark: true, immediate_mark: true, immediate_sweep: true)
      _, _, seq = GCStats.marking_times_since(nil)
      GC.start(full_mark: false, immediate_mark: true, immediate_sweep: true)
      GC.start(full_mark: true, immediate_mark: true, immediate_sweep: true)
      minor, major, = GCStats.marking_times_since(seq)

      assert_equal 1, minor.size
      assert_equal 1, major.size
      assert_operator major.first, :>, 0.0
    ensure
      GC::Profiler.disable unless was_enabled
    end

    it 'keeps the sequence when no collection finished' do
      assert_equal [[], [], 4], GCStats.marking_times_since(4, records: [], marking: false)
    end
  end

  describe '.aggregate' do
    it 'raises ArgumentError for an empty sample set' do
      error = assert_raises(ArgumentError) { GCStats.aggregate([]) }
      assert_equal 'Cannot aggregate an empty GC sample set', error.message
    end

    it 'sums only the whitelisted scalar fields across worker samples' do
      samples = [
        { 'gc_count' => 3, 'gc_global_count' => 1, 'gc_major_count' => 1, 'gc_minor_count' => 1, 'gc_marking_time' => 4, 'gc_sweeping_time' => 5, 'gc_total_time_ns' => 900_000, 'wall_time' => 0.01, 'worker_index' => 0, 'gc_stat_heap_delta' => { 0 => { heap_eden_slots: 2 } } },
        { 'gc_count' => 4, 'gc_global_count' => 2, 'gc_major_count' => 0, 'gc_minor_count' => 2, 'gc_marking_time' => 6, 'gc_sweeping_time' => 7, 'gc_total_time_ns' => 1_100_000, 'wall_time' => 0.02, 'worker_index' => 1, 'gc_stat_heap_delta' => { 1 => { heap_eden_slots: 5 } } }
      ]

      total = GCStats.aggregate(samples)

      assert_equal GCStats::SCALAR_FIELD_NAMES.sort, total.keys.sort
      assert_equal 7, total['gc_count']
      assert_equal 3, total['gc_global_count']
      assert_equal 1, total['gc_major_count']
      assert_equal 3, total['gc_minor_count']
      assert_equal 10, total['gc_marking_time']
      assert_equal 12, total['gc_sweeping_time']
      assert_equal 2_000_000, total['gc_total_time_ns']
    end

    it 'makes a field nil when any participating sample lacks a numeric value' do
      samples = [
        { 'gc_count' => 3, 'gc_major_count' => 1, 'gc_minor_count' => 2, 'gc_marking_time' => 4, 'gc_sweeping_time' => 5, 'gc_total_time_ns' => 900 },
        { 'gc_count' => 4, 'gc_major_count' => 0, 'gc_minor_count' => 4, 'gc_marking_time' => nil, 'gc_sweeping_time' => 7, 'gc_total_time_ns' => 100 }
      ]

      total = GCStats.aggregate(samples)

      assert_equal 7, total['gc_count']
      assert_nil total['gc_marking_time']
    end

    it 'keeps a supported all-zero aggregate as numeric zero' do
      samples = [
        { 'gc_count' => 0, 'gc_major_count' => 0, 'gc_minor_count' => 0, 'gc_marking_time' => 0, 'gc_sweeping_time' => 0, 'gc_total_time_ns' => 0 },
        { 'gc_count' => 0, 'gc_major_count' => 0, 'gc_minor_count' => 0, 'gc_marking_time' => 0, 'gc_sweeping_time' => 0, 'gc_total_time_ns' => 0 }
      ]

      total = GCStats.aggregate(samples)

      assert_equal 0, total['gc_count']
      refute_nil total['gc_total_time_ns']
    end
  end

  describe '.ractor_local_gc_supported?' do
    it 'rejects Ruby 4.0 builds' do
      refute GCStats.ractor_local_gc_supported?('4.0.6')
    end

    it 'accepts Ruby 4.1 and newer, comparing version parts as integers' do
      assert GCStats.ractor_local_gc_supported?('4.1.0dev')
      assert GCStats.ractor_local_gc_supported?('4.10.0')
      assert GCStats.ractor_local_gc_supported?('5.0.0')
    end

    it 'defaults to the running Ruby version' do
      assert_equal GCStats.ractor_local_gc_supported?(RUBY_VERSION), GCStats.ractor_local_gc_supported?
    end
  end

  describe '.measure' do
    it 'restores the GC measurement setting when the workload raises' do
      skip 'target lacks GC.measure_total_time=' unless GC.respond_to?(:measure_total_time) && GC.respond_to?(:measure_total_time=)

      saved = GC.measure_total_time
      begin
        GC.measure_total_time = false
        assert_raises(RuntimeError) { GCStats.measure { raise 'boom' } }
        assert_equal false, GC.measure_total_time
      ensure
        GC.measure_total_time = saved
      end
    end
  end

  describe '.global_gc_attributed?' do
    it 'is false when GC.stat lacks the global_gc_invocation_count key' do
      skip 'this build has the key; attribution depends on ruby/ruby#19383' if GCStats.stat_available?(:global_gc_invocation_count)
      refute GCStats.global_gc_attributed?
    end
  end
end
