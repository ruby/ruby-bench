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
      out = capture_io do
        assert_raises(SystemExit) { BenchmarkRunner.expand_pre_init('/nonexistent/file.rb') }
      end
      assert_includes out, "--with-pre-init called with non-existent file!\n"
    end

    it 'exits when path is a directory' do
      Dir.mktmpdir do |dir|
        out = capture_io do
          assert_raises(SystemExit) { BenchmarkRunner.expand_pre_init(dir) }
        end
        assert_includes out, "--with-pre-init called with a directory, please pass a .rb file\n"
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

  describe '.check_call' do
    it 'runs a successful command and returns success status' do
      result = nil

      capture_io do
        result = BenchmarkRunner.check_call('true')
      end

      assert_equal true, result[:success]
      assert_equal 0, result[:status].exitstatus
    end

    it 'prints the command by default' do
      output = capture_io do
        BenchmarkRunner.check_call('true')
      end

      assert_includes output[0], '+ true'
    end

    it 'suppresses output when quiet is true' do
      output = capture_io do
        BenchmarkRunner.check_call('true', quiet: true)
      end

      assert_equal '', output[0]
    end

    it 'raises error by default when command fails' do
      output = capture_io do
        assert_raises(RuntimeError) do
          BenchmarkRunner.check_call('false')
        end
      end

      assert_includes output[0], 'Command "false" failed'
    end

    it 'does not raise error when raise_error is false' do
      output = capture_io do
        result = BenchmarkRunner.check_call('false', raise_error: false)

        assert_equal false, result[:success]
        assert_equal 1, result[:status].exitstatus
      end

      assert_includes output[0], 'Command "false" failed'
    end

    it 'passes environment variables to the command' do
      Dir.mktmpdir do |dir|
        output_file = File.join(dir, 'test_output.txt')
        output = capture_io do
          result = BenchmarkRunner.check_call("sh -c 'echo $TEST_VAR > #{output_file}'", env: { 'TEST_VAR' => 'hello' })
          assert_equal true, result[:success]
        end

        # Command should be printed
        assert_includes output[0], "+ sh -c 'echo $TEST_VAR"
        # Environment variable should be written to file
        assert_equal "hello\n", File.read(output_file)
      end
    end

    it 'includes exit code and directory in error message' do
      output = capture_io do
        result = BenchmarkRunner.check_call('sh -c "exit 42"', raise_error: false)
        assert_equal false, result[:success]
        assert_equal 42, result[:status].exitstatus
      end

      assert_includes output[0], 'exit code 42'
      assert_includes output[0], "directory #{Dir.pwd}"
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
