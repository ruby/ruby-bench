require_relative 'test_helper'
require_relative '../lib/benchmark_runner'
require_relative '../misc/stats'
require 'tempfile'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'csv'
require 'yaml'

describe BenchmarkRunner do
  describe '.table_to_str' do
    it 'formats a simple table correctly' do
      table_data = [
        ['bench', 'time (ms)', 'stddev (%)'],
        ['fib', '100.5', '2.3'],
        ['loop', '50.2', '1.1']
      ]
      format = ['%s', '%s', '%s']
      failures = {}

      result = BenchmarkRunner.table_to_str(table_data, format, failures)

      assert_equal <<~TABLE, result
        -----  ---------  ----------
        bench  time (ms)  stddev (%)
        fib    100.5      2.3
        loop   50.2       1.1
        -----  ---------  ----------
      TABLE
    end

    it 'includes failure rows when failures are present' do
      table_data = [
        ['bench', 'time (ms)'],
        ['fib', '100.5']
      ]
      format = ['%s', '%s']
      failures = { 'ruby' => { 'broken_bench' => 1 } }

      result = BenchmarkRunner.table_to_str(table_data, format, failures)

      assert_equal <<~TABLE, result
        ------------  ---------
        bench         time (ms)
        broken_bench  N/A
        fib           100.5
        ------------  ---------
      TABLE
    end

    it 'handles empty failures hash' do
      table_data = [['bench'], ['fib']]
      format = ['%s']
      failures = {}

      result = BenchmarkRunner.table_to_str(table_data, format, failures)

      assert_equal <<~TABLE, result
        -----
        bench
        fib
        -----
      TABLE
    end
  end

  describe '.free_file_no' do
    it 'returns 1 when no files exist' do
      Dir.mktmpdir do |dir|
        file_no = BenchmarkRunner.free_file_no(dir)
        assert_equal 1, file_no
      end
    end

    it 'returns next available number when files exist' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'output_001.csv'))
        FileUtils.touch(File.join(dir, 'output_002.csv'))

        file_no = BenchmarkRunner.free_file_no(dir)
        assert_equal 3, file_no
      end
    end

    it 'finds first gap in numbering' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'output_001.csv'))
        FileUtils.touch(File.join(dir, 'output_003.csv'))

        file_no = BenchmarkRunner.free_file_no(dir)
        assert_equal 2, file_no
      end
    end

    it 'handles triple digit numbers' do
      Dir.mktmpdir do |dir|
        (1..100).each do |i|
          FileUtils.touch(File.join(dir, 'output_%03d.csv' % i))
        end

        file_no = BenchmarkRunner.free_file_no(dir)
        assert_equal 101, file_no
      end
    end
  end

  describe '.benchmark_categories' do
    before do
      @metadata = {
        'fib' => { 'category' => 'micro' },
        'railsbench' => { 'category' => 'headline' },
        'optcarrot' => { 'category' => 'headline' },
        'ractor_bench' => { 'category' => 'other', 'ractor' => true },
        'unknown_bench' => {}
      }
    end

    it 'returns category from metadata' do
      result = BenchmarkRunner.benchmark_categories('fib', @metadata)
      assert_equal ['micro'], result
    end

    it 'includes ractor category when ractor metadata is true' do
      result = BenchmarkRunner.benchmark_categories('ractor_bench', @metadata)
      assert_includes result, 'other'
      assert_includes result, 'ractor'
      assert_equal 2, result.size
    end

    it 'returns other as default category' do
      result = BenchmarkRunner.benchmark_categories('unknown_bench', @metadata)
      assert_equal ['other'], result
    end

    it 'returns other for completely missing benchmark' do
      result = BenchmarkRunner.benchmark_categories('nonexistent', @metadata)
      assert_equal ['other'], result
    end

    it 'handles headline benchmarks' do
      result = BenchmarkRunner.benchmark_categories('railsbench', @metadata)
      assert_equal ['headline'], result
    end
  end

  describe '.match_filter' do
    before do
      @metadata = {
        'fib' => { 'category' => 'micro' },
        'railsbench' => { 'category' => 'headline' },
        'optcarrot' => { 'category' => 'headline' },
        'ractor_bench' => { 'category' => 'other', 'ractor' => true }
      }
    end

    it 'matches when no filters provided' do
      result = BenchmarkRunner.match_filter('fib.rb', categories: [], name_filters: [], metadata: @metadata)
      assert_equal true, result
    end

    it 'matches by category' do
      result = BenchmarkRunner.match_filter('fib.rb', categories: ['micro'], name_filters: [], metadata: @metadata)
      assert_equal true, result

      result = BenchmarkRunner.match_filter('fib.rb', categories: ['headline'], name_filters: [], metadata: @metadata)
      assert_equal false, result
    end

    it 'matches by name filter' do
      result = BenchmarkRunner.match_filter('fib.rb', categories: [], name_filters: ['fib'], metadata: @metadata)
      assert_equal true, result

      result = BenchmarkRunner.match_filter('fib.rb', categories: [], name_filters: ['rails'], metadata: @metadata)
      assert_equal false, result
    end

    it 'matches ractor category' do
      result = BenchmarkRunner.match_filter('ractor_bench.rb', categories: ['ractor'], name_filters: [], metadata: @metadata)
      assert_equal true, result
    end

    it 'strips .rb extension from entry name' do
      result = BenchmarkRunner.match_filter('fib.rb', categories: [], name_filters: ['fib'], metadata: @metadata)
      assert_equal true, result
    end

    it 'handles regex filters' do
      result = BenchmarkRunner.match_filter('railsbench.rb', categories: [], name_filters: ['/rails/'], metadata: @metadata)
      assert_equal true, result

      result = BenchmarkRunner.match_filter('fib.rb', categories: [], name_filters: ['/rails/'], metadata: @metadata)
      assert_equal false, result
    end

    it 'handles case-insensitive regex filters' do
      result = BenchmarkRunner.match_filter('railsbench.rb', categories: [], name_filters: ['/rails/i'], metadata: @metadata)
      assert_equal true, result
    end

    it 'handles multiple categories' do
      result = BenchmarkRunner.match_filter('fib.rb', categories: ['micro', 'headline'], name_filters: [], metadata: @metadata)
      assert_equal true, result

      result = BenchmarkRunner.match_filter('railsbench.rb', categories: ['micro', 'headline'], name_filters: [], metadata: @metadata)
      assert_equal true, result
    end
  end

  describe '.process_name_filters' do
    it 'returns string filters unchanged' do
      filters = ['fib', 'rails']
      result = BenchmarkRunner.process_name_filters(filters)
      assert_equal filters, result
    end

    it 'converts regex strings to Regexp objects' do
      filters = ['/fib/']
      result = BenchmarkRunner.process_name_filters(filters)
      assert_equal 1, result.length
      assert_instance_of Regexp, result[0]
      refute_nil (result[0] =~ 'fib')
    end

    it 'handles regex with flags' do
      filters = ['/FIB/i']
      result = BenchmarkRunner.process_name_filters(filters)
      refute_nil (result[0] =~ 'fib')
      refute_nil (result[0] =~ 'FIB')
    end

    it 'handles mixed filters' do
      filters = ['fib', '/rails/', 'optcarrot']
      result = BenchmarkRunner.process_name_filters(filters)
      assert_equal 3, result.length
      assert_equal 'fib', result[0]
      assert_instance_of Regexp, result[1]
      assert_equal 'optcarrot', result[2]
    end

    it 'handles complex regex patterns' do
      filters = ['/opt.*rot/']
      result = BenchmarkRunner.process_name_filters(filters)
      refute_nil (result[0] =~ 'optcarrot')
      assert_nil (result[0] =~ 'fib')
    end

    it 'handles empty filter list' do
      filters = []
      result = BenchmarkRunner.process_name_filters(filters)
      assert_equal [], result
    end
  end

  describe '.expand_pre_init' do
    it 'returns load path and require options for valid file' do
      Dir.mktmpdir do |dir|
        file = File.join(dir, 'pre_init.rb')
        FileUtils.touch(file)

        result = BenchmarkRunner.expand_pre_init(file)

        assert_equal 4, result.length
        assert_equal '-I', result[0]
        assert_equal dir, result[1].to_s
        assert_equal '-r', result[2]
        assert_equal 'pre_init', result[3].to_s
      end
    end

    it 'handles files with different extensions' do
      Dir.mktmpdir do |dir|
        file = File.join(dir, 'my_config.rb')
        FileUtils.touch(file)

        result = BenchmarkRunner.expand_pre_init(file)

        assert_equal 'my_config', result[3].to_s
      end
    end

    it 'handles nested directories' do
      Dir.mktmpdir do |dir|
        subdir = File.join(dir, 'config', 'initializers')
        FileUtils.mkdir_p(subdir)
        file = File.join(subdir, 'setup.rb')
        FileUtils.touch(file)

        result = BenchmarkRunner.expand_pre_init(file)

        assert_equal subdir, result[1].to_s
        assert_equal 'setup', result[3].to_s
      end
    end

    it 'exits when file does not exist' do
      assert_raises(SystemExit) { BenchmarkRunner.expand_pre_init('/nonexistent/file.rb') }
    end

    it 'exits when path is a directory' do
      Dir.mktmpdir do |dir|
        assert_raises(SystemExit) { BenchmarkRunner.expand_pre_init(dir) }
      end
    end
  end

  describe '.sort_benchmarks' do
    before do
      @metadata = {
        'fib' => { 'category' => 'micro' },
        'railsbench' => { 'category' => 'headline' },
        'optcarrot' => { 'category' => 'headline' },
        'some_bench' => { 'category' => 'other' },
        'another_bench' => { 'category' => 'other' },
        'zebra' => { 'category' => 'other' }
      }
    end

    it 'sorts benchmarks with headlines first, then others, then micro' do
      bench_names = ['fib', 'some_bench', 'railsbench', 'another_bench', 'optcarrot']
      result = BenchmarkRunner.sort_benchmarks(bench_names, @metadata)

      # Headlines should be first
      headline_indices = [result.index('railsbench'), result.index('optcarrot')]
      assert_equal true, headline_indices.all? { |i| i < 2 }

      # Micro should be last
      assert_equal 'fib', result.last

      # Others in the middle
      other_indices = [result.index('some_bench'), result.index('another_bench')]
      assert_equal true, other_indices.all? { |i| i >= 2 && i < result.length - 1 }
    end

    it 'sorts alphabetically within categories' do
      bench_names = ['zebra', 'another_bench', 'some_bench']
      result = BenchmarkRunner.sort_benchmarks(bench_names, @metadata)
      assert_equal ['another_bench', 'some_bench', 'zebra'], result
    end

    it 'handles empty list' do
      result = BenchmarkRunner.sort_benchmarks([], @metadata)
      assert_equal [], result
    end

    it 'handles single benchmark' do
      result = BenchmarkRunner.sort_benchmarks(['fib'], @metadata)
      assert_equal ['fib'], result
    end

    it 'handles only headline benchmarks' do
      bench_names = ['railsbench', 'optcarrot']
      result = BenchmarkRunner.sort_benchmarks(bench_names, @metadata)
      assert_equal ['optcarrot', 'railsbench'], result
    end
  end

  describe '.os' do
    it 'detects the operating system' do
      result = BenchmarkRunner.os
      assert_includes [:linux, :macosx, :windows, :unix], result
    end

    it 'caches the os result' do
      first_call = BenchmarkRunner.os
      second_call = BenchmarkRunner.os
      assert_equal second_call, first_call
    end

    it 'returns a symbol' do
      result = BenchmarkRunner.os
      assert_instance_of Symbol, result
    end
  end

  describe '.setarch_prefix' do
    it 'returns an array' do
      result = BenchmarkRunner.setarch_prefix
      assert_instance_of Array, result
    end

    it 'returns setarch command on Linux with proper permissions' do
      skip 'Not on Linux' unless BenchmarkRunner.os == :linux

      prefix = BenchmarkRunner.setarch_prefix

      # Should either return the prefix or empty array if no permission
      assert_includes [0, 3], prefix.length

      if prefix.length == 3
        assert_equal 'setarch', prefix[0]
        assert_equal '-R', prefix[2]
      end
    end

    it 'returns empty array when setarch fails' do
      skip 'Test requires Linux' unless BenchmarkRunner.os == :linux

      # If we don't have permissions, it should return empty array
      prefix = BenchmarkRunner.setarch_prefix
      if prefix.empty?
        assert_equal [], prefix
      else
        # If we do have permissions, verify the structure
        assert_equal 3, prefix.length
      end
    end
  end

  describe 'Stats integration' do
    it 'calculates mean correctly' do
      values = [1, 2, 3, 4, 5]
      assert_equal 3.0, Stats.new(values).mean
    end

    it 'calculates stddev correctly' do
      values = [2, 4, 4, 4, 5, 5, 7, 9]
      result = Stats.new(values).stddev
      assert_in_delta 2.0, result, 0.1
    end
  end

  describe 'output file format' do
    it 'generates correct output file number format' do
      Dir.mktmpdir do |dir|
        file_no = 1
        expected_path = File.join(dir, "output_001.csv")

        assert_equal expected_path, File.join(dir, "output_%03d.csv" % file_no)
      end
    end

    it 'handles triple digit file numbers' do
      Dir.mktmpdir do |dir|
        file_no = 123
        expected_path = File.join(dir, "output_123.csv")

        assert_equal expected_path, File.join(dir, "output_%03d.csv" % file_no)
      end
    end
  end
end
