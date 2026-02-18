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

  describe '.output_path' do
    it 'returns the override path when provided' do
      Dir.mktmpdir do |dir|
        override = '/custom/path/output'
        result = BenchmarkRunner.output_path(dir, out_override: override)
        assert_equal override, result
      end
    end

    it 'generates path with first available file number when no override' do
      Dir.mktmpdir do |dir|
        result = BenchmarkRunner.output_path(dir)
        expected = File.join(dir, 'output_001')
        assert_equal expected, result
      end
    end

    it 'uses next available file number when files exist' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'output_001.csv'))
        FileUtils.touch(File.join(dir, 'output_002.csv'))

        result = BenchmarkRunner.output_path(dir)
        expected = File.join(dir, 'output_003')
        assert_equal expected, result
      end
    end

    it 'finds first gap in numbering when files are non-sequential' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'output_001.csv'))
        FileUtils.touch(File.join(dir, 'output_003.csv'))

        result = BenchmarkRunner.output_path(dir)
        expected = File.join(dir, 'output_002')
        assert_equal expected, result
      end
    end

    it 'prefers override even when files exist' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'output_001.csv'))

        override = '/override/path'
        result = BenchmarkRunner.output_path(dir, out_override: override)
        assert_equal override, result
      end
    end

    it 'handles triple digit file numbers' do
      Dir.mktmpdir do |dir|
        (1..100).each do |i|
          FileUtils.touch(File.join(dir, 'output_%03d.csv' % i))
        end

        result = BenchmarkRunner.output_path(dir)
        expected = File.join(dir, 'output_101')
        assert_equal expected, result
      end
    end
  end

  describe '.write_csv' do
    it 'writes CSV file with metadata and table data' do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, 'output_001')
        ruby_descriptions = {
          'ruby-base' => 'ruby 3.3.0',
          'ruby-yjit' => 'ruby 3.3.0 +YJIT'
        }
        table = [
          ['Benchmark', 'ruby-base', 'ruby-yjit'],
          ['fib', '1.5', '1.0'],
          ['matmul', '2.0', '1.8']
        ]

        result_path = BenchmarkRunner.write_csv(output_path, ruby_descriptions, table)

        expected_path = File.join(dir, 'output_001.csv')
        assert_equal expected_path, result_path
        assert File.exist?(expected_path)

        csv_rows = CSV.read(expected_path)
        assert_equal 'ruby-base', csv_rows[0][0]
        assert_equal 'ruby 3.3.0', csv_rows[0][1]
        assert_equal 'ruby-yjit', csv_rows[1][0]
        assert_equal 'ruby 3.3.0 +YJIT', csv_rows[1][1]
        assert_equal [], csv_rows[2]
        assert_equal table, csv_rows[3..5]
      end
    end

    it 'returns the CSV file path' do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, 'output_test')
        result_path = BenchmarkRunner.write_csv(output_path, {}, [])

        assert_equal File.join(dir, 'output_test.csv'), result_path
      end
    end

    it 'handles empty metadata and table' do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, 'output_empty')

        result_path = BenchmarkRunner.write_csv(output_path, {}, [])

        assert File.exist?(result_path)
        csv_rows = CSV.read(result_path)
        assert_equal [[]], csv_rows
      end
    end

    it 'handles single metadata entry' do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, 'output_single')
        ruby_descriptions = { 'ruby' => 'ruby 3.3.0' }
        table = [['Benchmark', 'Time'], ['test', '1.0']]

        result_path = BenchmarkRunner.write_csv(output_path, ruby_descriptions, table)

        csv_rows = CSV.read(result_path)
        assert_equal 'ruby', csv_rows[0][0]
        assert_equal 'ruby 3.3.0', csv_rows[0][1]
        assert_equal [], csv_rows[1]
        assert_equal table, csv_rows[2..3]
      end
    end

    it 'preserves precision in numeric strings' do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, 'output_precision')
        table = [['Benchmark', 'Time'], ['test', '1.234567890123']]

        result_path = BenchmarkRunner.write_csv(output_path, {}, table)

        csv_rows = CSV.read(result_path)
        assert_equal '1.234567890123', csv_rows[2][1]
      end
    end

    it 'overwrites existing CSV file' do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, 'output_overwrite')

        # Write first version
        BenchmarkRunner.write_csv(output_path, { 'v1' => 'first' }, [['old']])

        # Write second version
        new_descriptions = { 'v2' => 'second' }
        new_table = [['new']]
        result_path = BenchmarkRunner.write_csv(output_path, new_descriptions, new_table)

        csv_rows = CSV.read(result_path)
        assert_equal 'v2', csv_rows[0][0]
        assert_equal 'second', csv_rows[0][1]
      end
    end
  end

  describe '.write_json' do
    it 'writes JSON file with metadata and raw data' do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, 'output_001')
        ruby_descriptions = {
          'ruby-base' => 'ruby 3.3.0',
          'ruby-yjit' => 'ruby 3.3.0 +YJIT'
        }
        bench_data = {
          'ruby-base' => { 'fib' => { 'time' => 1.5 } },
          'ruby-yjit' => { 'fib' => { 'time' => 1.0 } }
        }

        result_path = BenchmarkRunner.write_json(output_path, ruby_descriptions, bench_data)

        expected_path = File.join(dir, 'output_001.json')
        assert_equal expected_path, result_path
        assert File.exist?(expected_path)

        json_content = JSON.parse(File.read(expected_path))
        assert_equal ruby_descriptions, json_content['metadata']
        assert_equal bench_data, json_content['raw_data']
      end
    end

    it 'returns the JSON file path' do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, 'output_test')
        result_path = BenchmarkRunner.write_json(output_path, {}, {})

        assert_equal File.join(dir, 'output_test.json'), result_path
      end
    end

    it 'handles empty metadata and bench data' do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, 'output_empty')

        result_path = BenchmarkRunner.write_json(output_path, {}, {})

        assert File.exist?(result_path)
        json_content = JSON.parse(File.read(result_path))
        assert_equal({}, json_content['metadata'])
        assert_equal({}, json_content['raw_data'])
      end
    end

    it 'handles nested benchmark data structures' do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, 'output_nested')
        ruby_descriptions = { 'ruby' => 'ruby 3.3.0' }
        bench_data = {
          'ruby' => {
            'benchmark1' => {
              'time' => 1.5,
              'rss' => 12345,
              'iterations' => [1.4, 1.5, 1.6]
            }
          }
        }

        result_path = BenchmarkRunner.write_json(output_path, ruby_descriptions, bench_data)

        json_content = JSON.parse(File.read(result_path))
        assert_equal bench_data, json_content['raw_data']
      end
    end

    it 'overwrites existing JSON file' do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, 'output_overwrite')

        # Write first version
        BenchmarkRunner.write_json(output_path, { 'v' => '1' }, { 'd' => '1' })

        # Write second version
        new_metadata = { 'v' => '2' }
        new_data = { 'd' => '2' }
        result_path = BenchmarkRunner.write_json(output_path, new_metadata, new_data)

        json_content = JSON.parse(File.read(result_path))
        assert_equal new_metadata, json_content['metadata']
        assert_equal new_data, json_content['raw_data']
      end
    end
  end

  describe '.build_output_text' do
    it 'builds output text with metadata, table, and legend' do
      ruby_descriptions = {
        'ruby-base' => 'ruby 3.3.0',
        'ruby-yjit' => 'ruby 3.3.0 +YJIT'
      }
      table = [
        ['bench', 'ruby-base (ms)', 'stddev (%)', 'ruby-yjit (ms)', 'stddev (%)'],
        ['fib', '100.0', '5.0', '50.0', '3.0']
      ]
      format = ['%s', '%.1f', '%.1f', '%.1f', '%.1f']
      bench_failures = {}

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, table, format, bench_failures
      )

      assert_includes result, 'ruby-base: ruby 3.3.0'
      assert_includes result, 'ruby-yjit: ruby 3.3.0 +YJIT'
      assert_includes result, 'Legend:'
      assert_includes result, '- ruby-yjit 1st itr: ratio of ruby-base/ruby-yjit time for the first benchmarking iteration.'
      assert_includes result, '- ruby-base/ruby-yjit: ratio of ruby-base/ruby-yjit time. Higher is better for ruby-yjit. Above 1 represents a speedup.'
      assert_includes result, "- ***: p < 0.001, **: p < 0.01, *: p < 0.05 (Welch's t-test)"
    end

    it 'includes RSS ratio legend when include_rss is true' do
      ruby_descriptions = {
        'ruby-base' => 'ruby 3.3.0',
        'ruby-yjit' => 'ruby 3.3.0 +YJIT'
      }
      table = [
        ['bench', 'ruby-base (ms)', 'stddev (%)', 'RSS (MiB)', 'ruby-yjit (ms)', 'stddev (%)', 'RSS (MiB)', 'ruby-yjit 1st itr', 'ruby-base/ruby-yjit', 'RSS ruby-base/ruby-yjit'],
        ['fib', '100.0', '5.0', '10.0', '50.0', '3.0', '12.0', '2.000', '2.000', '0.833']
      ]
      format = ['%s', '%.1f', '%.1f', '%.1f', '%.1f', '%.1f', '%.1f', '%.3f', '%s', '%.3f']
      bench_failures = {}

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, table, format, bench_failures, include_rss: true
      )

      assert_includes result, '- RSS ruby-base/ruby-yjit: ratio of ruby-base/ruby-yjit RSS. Higher is better for ruby-yjit. Above 1 means lower memory usage.'
    end

    it 'omits RSS ratio legend when include_rss is false' do
      ruby_descriptions = {
        'ruby-base' => 'ruby 3.3.0',
        'ruby-yjit' => 'ruby 3.3.0 +YJIT'
      }
      table = [
        ['bench', 'ruby-base (ms)', 'stddev (%)', 'ruby-yjit (ms)', 'stddev (%)'],
        ['fib', '100.0', '5.0', '50.0', '3.0']
      ]
      format = ['%s', '%.1f', '%.1f', '%.1f', '%.1f']
      bench_failures = {}

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, table, format, bench_failures
      )

      refute_includes result, 'RSS ruby-base/ruby-yjit'
    end

    it 'includes formatted table in output' do
      ruby_descriptions = { 'ruby' => 'ruby 3.3.0' }
      table = [
        ['bench', 'ruby (ms)', 'stddev (%)'],
        ['fib', '100.0', '5.0']
      ]
      format = ['%s', '%.1f', '%.1f']
      bench_failures = {}

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, table, format, bench_failures
      )

      # Should contain table headers
      assert_includes result, 'bench'
      assert_includes result, 'ruby (ms)'
      # Should contain table data
      assert_includes result, 'fib'
      assert_includes result, '100.0'
    end

    it 'omits legend when no other executables' do
      ruby_descriptions = { 'ruby' => 'ruby 3.3.0' }
      table = [['bench', 'ruby (ms)'], ['fib', '100.0']]
      format = ['%s', '%.1f']
      bench_failures = {}

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, table, format, bench_failures
      )

      refute_includes result, 'Legend:'
    end

    it 'handles multiple other executables in legend' do
      ruby_descriptions = {
        'ruby' => 'ruby 3.3.0',
        'ruby-yjit' => 'ruby 3.3.0 +YJIT',
        'ruby-rjit' => 'ruby 3.3.0 +RJIT'
      }
      table = [['bench', 'ruby (ms)', 'ruby-yjit (ms)', 'ruby-rjit (ms)']]
      format = ['%s', '%.1f', '%.1f', '%.1f']
      bench_failures = {}

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, table, format, bench_failures
      )

      assert_includes result, 'ruby-yjit 1st itr'
      assert_includes result, 'ruby-rjit 1st itr'
      assert_includes result, 'ruby/ruby-yjit'
      assert_includes result, 'ruby/ruby-rjit'
    end

    it 'includes benchmark failures in formatted output' do
      ruby_descriptions = { 'ruby' => 'ruby 3.3.0' }
      table = [['bench', 'ruby (ms)'], ['fib', '100.0']]
      format = ['%s', '%.1f']
      bench_failures = {
        'ruby' => { 'failed_bench' => 'error message' }
      }

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, table, format, bench_failures
      )

      # TableFormatter handles displaying failures, just verify it's called
      assert_kind_of String, result
      assert result.length > 0
    end

    it 'handles empty ruby_descriptions' do
      ruby_descriptions = {}
      table = [['bench']]
      format = ['%s']
      bench_failures = {}

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, table, format, bench_failures
      )

      assert_kind_of String, result
      assert result.start_with?("\n") # Should start with newline after empty descriptions
    end

    it 'preserves order of ruby_descriptions' do
      ruby_descriptions = {
        'ruby-a' => 'version A',
        'ruby-b' => 'version B',
        'ruby-c' => 'version C'
      }
      table = [['bench']]
      format = ['%s']
      bench_failures = {}

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, table, format, bench_failures
      )

      lines = result.lines
      assert_includes lines[0], 'ruby-a: version A'
      assert_includes lines[1], 'ruby-b: version B'
      assert_includes lines[2], 'ruby-c: version C'
    end
  end

  describe '.render_graph' do
    it 'delegates to GraphRenderer and returns calculated png_path' do
      skip 'rmagick segfaults on truffleruby 25.0.0' if RUBY_ENGINE == 'truffleruby'
      Dir.mktmpdir do |dir|
        json_path = File.join(dir, 'test.json')
        expected_png_path = File.join(dir, 'test.png')

        json_data = {
          metadata: { 'ruby-a' => 'version A' },
          raw_data: { 'ruby-a' => { 'bench1' => { 'bench' => [1.0] } } }
        }
        File.write(json_path, JSON.generate(json_data))

        result = BenchmarkRunner.render_graph(json_path)

        assert_equal expected_png_path, result
        assert File.exist?(expected_png_path)
      end
    end
  end
end
