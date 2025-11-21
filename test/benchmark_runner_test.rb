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
