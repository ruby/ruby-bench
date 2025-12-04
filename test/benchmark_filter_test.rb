require_relative 'test_helper'
require_relative '../lib/benchmark_filter'
require_relative '../lib/benchmark_runner'
require_relative '../lib/benchmark_discovery'

describe BenchmarkFilter do
  before do
    @metadata = {
      'fib' => { 'category' => 'micro' },
      'railsbench' => { 'category' => 'headline' },
      'optcarrot' => { 'category' => 'headline' },
      'ractor_bench' => { 'category' => 'other', 'ractor' => true }
    }
  end

  describe '#match?' do
    it 'matches when no filters provided' do
      filter = BenchmarkFilter.new(categories: [], name_filters: [], excludes: [], metadata: @metadata)

      assert_equal true, filter.match?('fib')
    end

    it 'matches by category' do
      filter = BenchmarkFilter.new(categories: ['micro'], name_filters: [], excludes: [], metadata: @metadata)

      assert_equal true, filter.match?('fib')
      assert_equal false, filter.match?('railsbench')
    end

    it 'matches by name filter' do
      filter = BenchmarkFilter.new(categories: [], name_filters: ['fib'], excludes: [], metadata: @metadata)

      assert_equal true, filter.match?('fib')
      assert_equal false, filter.match?('railsbench')
    end

    it 'applies excludes' do
      filter = BenchmarkFilter.new(categories: ['headline'], name_filters: [], excludes: ['railsbench'], metadata: @metadata)

      assert_equal true, filter.match?('optcarrot')
      assert_equal false, filter.match?('railsbench')
    end

    it 'matches ractor category' do
      filter = BenchmarkFilter.new(categories: ['ractor'], name_filters: [], excludes: [], metadata: @metadata)

      assert_equal true, filter.match?('ractor_bench')
    end

    it 'excludes ractor harness benchmarks from default runs' do
      metadata = @metadata.merge('ractor_harness_bench' => { 'category' => 'other', 'ractor' => true, 'default_harness' => 'harness-ractor' })
      filter = BenchmarkFilter.new(categories: [], name_filters: [], excludes: [], metadata: metadata)

      assert_equal true, filter.match?('fib')
      assert_equal true, filter.match?('ractor_bench') # ractor: true without harness-ractor runs in default
      assert_equal false, filter.match?('ractor_harness_bench') # ractor: true with harness-ractor excluded
    end

    it 'includes ractor harness benchmarks in ractor category' do
      metadata = @metadata.merge('ractor_harness_bench' => { 'category' => 'other', 'ractor' => true, 'default_harness' => 'harness-ractor' })
      filter = BenchmarkFilter.new(categories: ['ractor'], name_filters: [], excludes: [], metadata: metadata)

      assert_equal true, filter.match?('ractor_harness_bench')
      assert_equal true, filter.match?('ractor_bench')
    end

    it 'handles regex filters' do
      filter = BenchmarkFilter.new(categories: [], name_filters: ['/rails/'], excludes: [], metadata: @metadata)

      assert_equal true, filter.match?('railsbench')
      assert_equal false, filter.match?('fib')
    end

    it 'handles case-insensitive regex filters' do
      filter = BenchmarkFilter.new(categories: [], name_filters: ['/RAILS/i'], excludes: [], metadata: @metadata)

      assert_equal true, filter.match?('railsbench')
    end

    it 'handles multiple categories' do
      filter = BenchmarkFilter.new(categories: ['micro', 'headline'], name_filters: [], excludes: [], metadata: @metadata)

      assert_equal true, filter.match?('fib')
      assert_equal true, filter.match?('railsbench')
    end

    it 'requires both category and name filter to match when both provided' do
      filter = BenchmarkFilter.new(categories: ['micro'], name_filters: ['rails'], excludes: [], metadata: @metadata)

      assert_equal false, filter.match?('fib') # matches category but not name
      assert_equal false, filter.match?('railsbench') # matches name but not category
    end

    it 'handles complex regex patterns' do
      filter = BenchmarkFilter.new(categories: [], name_filters: ['/opt.*rot/'], excludes: [], metadata: @metadata)

      assert_equal true, filter.match?('optcarrot')
      assert_equal false, filter.match?('fib')
    end

    it 'handles mixed string and regex filters' do
      filter = BenchmarkFilter.new(categories: [], name_filters: ['fib', '/rails/'], excludes: [], metadata: @metadata)

      assert_equal true, filter.match?('fib')
      assert_equal true, filter.match?('railsbench')
      assert_equal false, filter.match?('optcarrot')
    end

    it 'matches directory prefix for multi-benchmark directories' do
      metadata = {
        'addressable-equality' => { 'category' => 'other' },
        'addressable-join' => { 'category' => 'other' },
        'addressable-parse' => { 'category' => 'other' },
        'fib' => { 'category' => 'micro' }
      }

      filter = BenchmarkFilter.new(
        categories: [],
        name_filters: ['addressable'],
        excludes: [],
        metadata: metadata,
        directory_map: {
          'addressable-equality' => 'addressable',
          'addressable-join' => 'addressable',
          'addressable-parse' => 'addressable',
          'fib' => nil
        }
      )

      assert_equal true, filter.match?('addressable-equality')
      assert_equal true, filter.match?('addressable-join')
      assert_equal true, filter.match?('addressable-parse')

      assert_equal false, filter.match?('fib')
    end

    it 'matches exact name when there is no hyphen' do
      metadata = {
        'erubi' => { 'category' => 'other' },
        'erubi-rails' => { 'category' => 'headline' },
        'fib' => { 'category' => 'micro' }
      }

      filter = BenchmarkFilter.new(
        categories: [],
        name_filters: ['erubi'],
        excludes: [],
        metadata: metadata,
        directory_map: {
          'erubi' => 'erubi',
          'erubi-rails' => 'erubi-rails',
          'fib' => nil
        }
      )

      assert_equal true, filter.match?('erubi')

      assert_equal false, filter.match?('erubi-rails')

      assert_equal false, filter.match?('fib')
    end

    it 'allows specific benchmark names with prefix matching disabled via exact match' do
      metadata = {
        'addressable-equality' => { 'category' => 'other' },
        'addressable-join' => { 'category' => 'other' }
      }

      filter = BenchmarkFilter.new(categories: [], name_filters: ['addressable-equality'], excludes: [], metadata: metadata)

      assert_equal true, filter.match?('addressable-equality')

      assert_equal false, filter.match?('addressable-join')
    end

    it 'prefix matching works with multiple filters' do
      metadata = {
        'addressable-equality' => { 'category' => 'other' },
        'addressable-join' => { 'category' => 'other' },
        'erubi' => { 'category' => 'other' },
        'erubi-rails' => { 'category' => 'headline' },
        'fib' => { 'category' => 'micro' }
      }

      filter = BenchmarkFilter.new(
        categories: [],
        name_filters: ['addressable', 'fib'],
        excludes: [],
        metadata: metadata,
        directory_map: {
          'addressable-equality' => 'addressable',
          'addressable-join' => 'addressable',
          'erubi' => 'erubi',
          'erubi-rails' => 'erubi-rails',
          'fib' => nil
        }
      )

      assert_equal true, filter.match?('addressable-equality')
      assert_equal true, filter.match?('addressable-join')

      assert_equal true, filter.match?('fib')

      assert_equal false, filter.match?('erubi')
      assert_equal false, filter.match?('erubi-rails')
    end

    it 'regex filters are not affected by prefix matching logic' do
      metadata = {
        'addressable-equality' => { 'category' => 'other' },
        'addressable-join' => { 'category' => 'other' },
        'fib' => { 'category' => 'micro' }
      }

      filter = BenchmarkFilter.new(
        categories: [],
        name_filters: ['/addr.*able/'],
        excludes: [],
        metadata: metadata,
        directory_map: {
          'addressable-equality' => 'addressable',
          'addressable-join' => 'addressable',
          'fib' => nil
        }
      )

      assert_equal true, filter.match?('addressable-equality')
      assert_equal true, filter.match?('addressable-join')
      assert_equal false, filter.match?('fib')
    end
  end
end
