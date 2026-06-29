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
  end
end
