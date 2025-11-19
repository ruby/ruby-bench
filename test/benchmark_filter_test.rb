require_relative 'test_helper'
require_relative '../lib/benchmark_filter'
require_relative '../lib/benchmark_runner'

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
      filter = BenchmarkFilter.new(categories: [], name_filters: [], metadata: @metadata)

      assert_equal true, filter.match?('fib.rb')
    end

    it 'matches by category' do
      filter = BenchmarkFilter.new(categories: ['micro'], name_filters: [], metadata: @metadata)

      assert_equal true, filter.match?('fib.rb')
      assert_equal false, filter.match?('railsbench.rb')
    end

    it 'matches by name filter' do
      filter = BenchmarkFilter.new(categories: [], name_filters: ['fib'], metadata: @metadata)

      assert_equal true, filter.match?('fib.rb')
      assert_equal false, filter.match?('railsbench.rb')
    end

    it 'matches ractor category' do
      filter = BenchmarkFilter.new(categories: ['ractor'], name_filters: [], metadata: @metadata)

      assert_equal true, filter.match?('ractor_bench.rb')
    end

    it 'strips .rb extension from entry name' do
      filter = BenchmarkFilter.new(categories: [], name_filters: ['fib'], metadata: @metadata)

      assert_equal true, filter.match?('fib.rb')
    end

    it 'handles regex filters' do
      filter = BenchmarkFilter.new(categories: [], name_filters: ['/rails/'], metadata: @metadata)

      assert_equal true, filter.match?('railsbench.rb')
      assert_equal false, filter.match?('fib.rb')
    end

    it 'handles case-insensitive regex filters' do
      filter = BenchmarkFilter.new(categories: [], name_filters: ['/RAILS/i'], metadata: @metadata)

      assert_equal true, filter.match?('railsbench.rb')
    end

    it 'handles multiple categories' do
      filter = BenchmarkFilter.new(categories: ['micro', 'headline'], name_filters: [], metadata: @metadata)

      assert_equal true, filter.match?('fib.rb')
      assert_equal true, filter.match?('railsbench.rb')
    end

    it 'requires both category and name filter to match when both provided' do
      filter = BenchmarkFilter.new(categories: ['micro'], name_filters: ['rails'], metadata: @metadata)

      assert_equal false, filter.match?('fib.rb') # matches category but not name
      assert_equal false, filter.match?('railsbench.rb') # matches name but not category
    end

    it 'handles complex regex patterns' do
      filter = BenchmarkFilter.new(categories: [], name_filters: ['/opt.*rot/'], metadata: @metadata)

      assert_equal true, filter.match?('optcarrot.rb')
      assert_equal false, filter.match?('fib.rb')
    end

    it 'handles mixed string and regex filters' do
      filter = BenchmarkFilter.new(categories: [], name_filters: ['fib', '/rails/'], metadata: @metadata)

      assert_equal true, filter.match?('fib.rb')
      assert_equal true, filter.match?('railsbench.rb')
      assert_equal false, filter.match?('optcarrot.rb')
    end
  end
end
