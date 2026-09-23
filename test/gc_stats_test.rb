require_relative 'test_helper'
require_relative '../harness/gc-stats'

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

  describe '.aggregate' do
    it 'raises ArgumentError for an empty sample set' do
      error = assert_raises(ArgumentError) { GCStats.aggregate([]) }
      assert_equal 'Cannot aggregate an empty GC sample set', error.message
    end

    it 'sums only the whitelisted scalar fields across worker samples' do
      samples = [
        { 'gc_count' => 3, 'gc_major_count' => 1, 'gc_minor_count' => 2, 'gc_marking_time' => 4, 'gc_sweeping_time' => 5, 'gc_total_time_ns' => 900_000, 'wall_time' => 0.01, 'worker_index' => 0, 'gc_stat_heap_delta' => { 0 => { heap_eden_slots: 2 } } },
        { 'gc_count' => 4, 'gc_major_count' => 0, 'gc_minor_count' => 4, 'gc_marking_time' => 6, 'gc_sweeping_time' => 7, 'gc_total_time_ns' => 1_100_000, 'wall_time' => 0.02, 'worker_index' => 1, 'gc_stat_heap_delta' => { 1 => { heap_eden_slots: 5 } } }
      ]

      total = GCStats.aggregate(samples)

      assert_equal GCStats::SCALAR_FIELD_NAMES.sort, total.keys.sort
      assert_equal 7, total['gc_count']
      assert_equal 1, total['gc_major_count']
      assert_equal 6, total['gc_minor_count']
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
end
