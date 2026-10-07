require_relative 'test_helper'
require_relative '../lib/ractor_breakdown'

describe RactorBreakdown do
  describe '.expand' do
    it 'leaves regular blobs (no bench_by_ractors) untouched' do
      bench_data = {
        'ruby' => {
          'fib' => { 'bench' => [0.1, 0.2], 'rss' => 100 }
        }
      }

      result = RactorBreakdown.expand(bench_data)

      assert_equal bench_data, result.bench_data
      assert_empty result.groups
    end

    it 'splits a ractor blob into one synthetic blob per count' do
      bench_data = {
        'ruby' => {
          'symbol-name-ractor' => {
            'bench' => [1.0, 2.0, 3.0, 4.0],
            'bench_by_ractors' => {
              '0' => [1.0, 1.1],
              '2' => [2.0, 2.2]
            },
            'rss' => 555,
            'warmup' => []
          }
        }
      }

      result = RactorBreakdown.expand(bench_data)
      exe = result.bench_data['ruby']

      key0 = "symbol-name-ractor\x000"
      key2 = "symbol-name-ractor\x002"

      assert_equal [1.0, 1.1], exe[key0]['bench']
      assert_equal [2.0, 2.2], exe[key2]['bench']
      # process-wide fields are shared
      assert_equal 555, exe[key0]['rss']
      assert_equal 555, exe[key2]['rss']
      # original flat entry is removed
      refute exe.key?('symbol-name-ractor')
    end

    it 'reports groups in numeric count order with base name and data keys' do
      bench_data = {
        'ruby' => {
          'symbol-name-ractor' => {
            'bench' => [],
            'bench_by_ractors' => { '8' => [1.0], '0' => [1.0], '2' => [1.0] }
          }
        }
      }

      result = RactorBreakdown.expand(bench_data)

      assert_equal(
        [['symbol-name-ractor', [
          ["symbol-name-ractor\x000", 0],
          ["symbol-name-ractor\x002", 2],
          ["symbol-name-ractor\x008", 8]
        ]]],
        result.groups
      )
    end

    it 'expands the same benchmark across all executables consistently' do
      blob = lambda do
        {
          'bench' => [],
          'bench_by_ractors' => { '0' => [1.0], '1' => [2.0] }
        }
      end
      bench_data = {
        'ruby'      => { 'r' => blob.call },
        'ruby-yjit' => { 'r' => blob.call }
      }

      result = RactorBreakdown.expand(bench_data)

      assert result.bench_data['ruby'].key?("r\x000")
      assert result.bench_data['ruby-yjit'].key?("r\x000")
      # groups computed once, not duplicated per executable
      assert_equal 1, result.groups.size
    end

    it 'merges only the matching count\'s gc_by_ractors entry into each synthetic blob' do
      blob = {
        'bench' => [3.0],
        'bench_by_ractors' => { '0' => [1.0], '2' => [2.0] },
        'gc_scope' => 'ractor-local-workload',
        'gc_by_ractors' => {
          '0' => {
            'gc_count_bench' => [10],
            'gc_total_time_bench' => [4.0],
            'gc_worker_samples' => [[{ 'gc_count' => 10 }]]
          },
          '2' => {
            'gc_count_bench' => [99],
            'gc_total_time_bench' => [12.0],
            'gc_worker_samples' => [[{ 'gc_count' => 50 }, { 'gc_count' => 49 }]],
            'gc_controller_samples' => [{ 'gc_count' => 1 }]
          }
        },
        'rss' => 555
      }

      blob['gc_stat_scope'] = 'ractor-local'
      blob['gc_measure_total_time_scope'] = 'ractor-local'
      blob['gc_config'] = { 'implementation' => 'default' }

      result = RactorBreakdown.expand({ 'ruby' => { 'r' => blob } })
      exe = result.bench_data['ruby']
      key0 = "r\x000"
      key2 = "r\x002"

      assert_equal [10], exe[key0]['gc_count_bench']
      assert_equal [4.0], exe[key0]['gc_total_time_bench']
      assert_equal [99], exe[key2]['gc_count_bench']
      assert_equal [12.0], exe[key2]['gc_total_time_bench']
      refute exe[key0].key?('gc_controller_samples')
      assert_equal [{ 'gc_count' => 1 }], exe[key2]['gc_controller_samples']

      refute exe[key0].key?('gc_by_ractors')
      refute exe[key2].key?('gc_by_ractors')
      refute exe[key0].key?('bench_by_ractors')
      assert_equal 'ractor-local-workload', exe[key0]['gc_scope']
      assert_equal 'ractor-local-workload', exe[key2]['gc_scope']

      [key0, key2].each do |key|
        assert_equal 'ractor-local', exe[key]['gc_stat_scope']
        assert_equal 'ractor-local', exe[key]['gc_measure_total_time_scope']
        assert_equal({ 'implementation' => 'default' }, exe[key]['gc_config'])
      end
      assert_equal 555, exe[key2]['rss']
    end

    it 'produces the old timing-only per-count blob when a count lacks GC data' do
      bench_data = {
        'ruby' => {
          'r' => {
            'bench' => [1.0],
            'bench_by_ractors' => { '0' => [1.0] },
            'gc_scope' => 'ractor-local-workload',
            'gc_stat_scope' => 'ractor-local',
            'gc_measure_total_time_scope' => 'ractor-local',
            'gc_config' => { 'implementation' => 'default' }
          }
        }
      }

      result = RactorBreakdown.expand(bench_data)
      per_count = result.bench_data['ruby']["r\x000"]

      assert_equal [1.0], per_count['bench']
      refute per_count.key?('gc_count_bench')
      refute per_count.key?('gc_by_ractors')
      refute per_count.key?('gc_scope')
      assert_equal 'ractor-local', per_count['gc_stat_scope']
      assert_equal 'ractor-local', per_count['gc_measure_total_time_scope']
      assert_equal({ 'implementation' => 'default' }, per_count['gc_config'])
    end
  end

  describe '.merge' do
    def child_blob(count, bench:, rss:, zjit_calls:)
      {
        'RUBY_DESCRIPTION' => 'ruby 4.1.0',
        'warmup' => [],
        'bench' => bench,
        'bench_by_ractors' => { count.to_s => bench },
        'gc_scope' => 'ractor-local-workload',
        'gc_by_ractors' => { count.to_s => { 'gc_count_bench' => [count * 10] } },
        'rss' => rss,
        'maxrss' => 500,
        'zjit_stats' => { 'calls' => zjit_calls },
        'command_line' => "RUBY_BENCH_RACTORS=#{count} ruby bench.rb"
      }
    end

    it 'keeps process-level data per count so each expanded row shows its own process' do
      merged = RactorBreakdown.merge(
        2 => child_blob(2, bench: [2.0, 2.1], rss: 300, zjit_calls: 7),
        0 => child_blob(0, bench: [1.0, 1.1], rss: 100, zjit_calls: 5)
      )

      assert_equal({ '0' => [1.0, 1.1], '2' => [2.0, 2.1] }, merged['bench_by_ractors'])
      assert_equal [1.0, 1.1, 2.0, 2.1], merged['bench']
      refute merged.key?('rss')
      refute merged.key?('maxrss'), 'equal process-level values must stay per count'
      assert_equal 'ruby 4.1.0', merged['RUBY_DESCRIPTION']
      assert_equal 'ractor-local-workload', merged['gc_scope']
      refute merged.key?('zjit_stats')
      refute merged.key?('command_line')
      assert_equal %w[rss maxrss zjit_stats command_line], merged['results_by_ractors']['0'].keys

      exe = RactorBreakdown.expand({ 'ruby' => { 'r' => merged } }).bench_data['ruby']
      r0 = exe["r\x000"]
      r2 = exe["r\x002"]

      assert_equal [1.0, 1.1], r0['bench']
      assert_equal 100, r0['rss']
      assert_equal 300, r2['rss']
      assert_equal({ 'calls' => 5 }, r0['zjit_stats'])
      assert_equal({ 'calls' => 7 }, r2['zjit_stats'])
      assert_equal [0], r0['gc_count_bench']
      assert_equal [20], r2['gc_count_bench']
      assert_equal 'RUBY_BENCH_RACTORS=2 ruby bench.rb', r2['command_line']
      refute r0.key?('results_by_ractors')
    end
  end
end
