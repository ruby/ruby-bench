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
  describe '.ruby_bench_revision' do
    def git(dir, *args)
      system('git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t', *args, out: File::NULL, err: File::NULL) or raise "git #{args.join(' ')} failed"
    end

    it 'returns the HEAD commit, with -dirty only when tracked files change' do
      Dir.mktmpdir do |dir|
        git(dir, 'init', '-q')
        File.write(File.join(dir, 'a.rb'), "1\n")
        git(dir, 'add', 'a.rb')
        git(dir, 'commit', '-q', '-m', 'init')
        head = IO.popen(['git', '-C', dir, 'rev-parse', 'HEAD'], &:read).strip

        File.write(File.join(dir, 'untracked.txt'), "x\n")
        assert_equal head, BenchmarkRunner.ruby_bench_revision(dir)

        File.write(File.join(dir, 'a.rb'), "2\n")
        assert_equal "#{head}-dirty", BenchmarkRunner.ruby_bench_revision(dir)
      end
    end

    it 'returns unknown outside a git checkout' do
      Dir.mktmpdir do |dir|
        assert_equal 'unknown', BenchmarkRunner.ruby_bench_revision(dir)
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
      refute_includes result, "p < 0.001"
    end

    it 'includes p-value legend when include_pvalue is true' do
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
        ruby_descriptions, table, format, bench_failures, include_pvalue: true
      )

      assert_includes result, "- ***: p < 0.001, **: p < 0.01, *: p < 0.05 (Welch's t-test)"
    end

    it 'prints compact GC comparison table and legend when include_gc is true' do
      ruby_descriptions = {
        'ruby-base' => 'ruby 3.3.0',
        'ruby-exp' => 'ruby 3.3.0 experiment'
      }
      table = [
        ['bench', 'ruby-base (ms)', 'ruby-exp (ms)', 'ruby-base/ruby-exp'],
        ['fib', '100.0', '50.0', '2.000']
      ]
      format = ['%s', '%s', '%s', '%s']
      gc_table = [
        ['bench', 'mark/iter ratio', 'sweep/iter ratio', 'mark/GC ratio', 'sweep/GC ratio', 'major/iter', 'minor/iter', 'minor GC %'],
        ['fib', '2.000', '1.250', '1.000', '0.625', ' 2.0  →   1.0', ' 8.0  →   4.0', ' 80%  →   80%']
      ]
      gc_format = ['%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s']
      bench_failures = {}

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, table, format, bench_failures, include_gc: true, gc_table: gc_table, gc_format: gc_format
      )

      assert_includes result, "GC summary:\n"
      assert_includes result, 'mark/GC ratio'
      assert_includes result, ' 2.0  →   1.0'
      assert_includes result, '- GC summary compares ruby-base → comparison. Ratio columns are ruby-base/comparison; above 1 means the comparison spent less GC time.'
      refute_includes result, 'mark ruby-base/ruby-exp:'
    end

    it 'explains the controller compaction column when a GC table shows it' do
      ruby_descriptions = {
        'ruby-base' => 'ruby 4.1.0dev',
        'ruby-exp' => 'ruby 4.1.0dev experiment'
      }
      table = [
        ['bench', 'ruby-base (ms)', 'ruby-exp (ms)', 'ruby-base/ruby-exp'],
        ['fib', '100.0', '50.0', '2.000']
      ]
      format = ['%s', '%s', '%s', '%s']
      gc_table = [
        ['bench', 'gc/iter ratio', 'global/iter ratio', 'GCs/iter', 'controller compacts/iter*'],
        ['fib', '2.000', '1.500', '10.0  →   5.0', ' 1.0  →   2.0']
      ]
      gc_format = ['%s', '%s', '%s', '%s', '%s']

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, table, format, {}, include_gc: true, gc_table: gc_table, gc_format: gc_format
      )

      assert_includes result, "GC metric notes:\n"
      assert_includes result, "- controller compacts/iter*: the main Ractor's GC.stat(:compact_count) delta per iteration."
      assert_includes result, 'Every global compacting cycle increments compact_count in every object space.'
      assert_includes result, 'Do not sum it across workers.'
      assert_includes result, 'GC summary shows ruby-base → comparison values.'
      refute_includes result, 'GC per ruby shows the value for each ruby.'
      refute_includes result, 'global GCs/iter'
    end

    it 'explains the compaction column for a single-executable GC table without a legend' do
      ruby_descriptions = { 'ruby' => 'ruby 4.1.0dev' }
      table = [['bench', 'ruby (ms)'], ['fib', '100.0']]
      format = ['%s', '%s']
      gc_table = [
        ['bench', 'GC ms/iter', 'GCs/iter', 'global/iter', 'controller compacts/iter*'],
        ['fib', '4.000', '10.0', '1.0', '0.0']
      ]
      gc_format = ['%s', '%s', '%s', '%s', '%s']

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, table, format, {}, include_gc: true, gc_table: gc_table, gc_format: gc_format
      )

      refute_includes result, 'Legend:'
      assert_includes result, "GC metric notes:\n"
      assert_includes result, "- controller compacts/iter*: the main Ractor's GC.stat(:compact_count) delta per iteration."
      refute_includes result, 'GC summary shows'
      refute_includes result, 'global GCs/iter'
    end

    it 'omits the GC metric notes block when no GC table shows those columns' do
      ruby_descriptions = {
        'ruby-base' => 'ruby 3.3.0',
        'ruby-exp' => 'ruby 3.3.0 experiment'
      }
      table = [
        ['bench', 'ruby-base (ms)', 'ruby-exp (ms)', 'ruby-base/ruby-exp'],
        ['fib', '100.0', '50.0', '2.000']
      ]
      format = ['%s', '%s', '%s', '%s']
      gc_table = [
        ['bench', 'mark/iter ratio', 'GCs/iter', 'global/iter'],
        ['fib', '2.000', '10.0  →   5.0', ' 2.0  →   1.0']
      ]
      gc_format = ['%s', '%s', '%s', '%s']

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, table, format, {}, include_gc: true, gc_table: gc_table, gc_format: gc_format
      )

      refute_includes result, 'GC metric notes:'
      assert_includes result, "the same run's GCs/iter count"
      assert_includes result, 'In GC summary, GCs/iter, major/iter, minor/iter, controller compacts/iter*, and minor GC % show ruby-base → comparison values, not ratios. A row is omitted when neither ruby-base nor the comparison has GC activity.'
    end

    it 'omits the Ractor scope note when the section rendered no GC table' do
      ruby_descriptions = { 'ruby' => 'ruby 4.1.0dev' }
      sections = [
        {
          title: 'harness-ractor',
          table: [['bench', 'ractors', 'ruby (ms)'], ['object-new', '0', '200.0']],
          format: ['%s', '%s', '%.1f'],
          failures: {},
          include_gc: true,
          gc_table: nil,
          gc_scope: 'ractor-local-workload',
        }
      ]

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, sections.first[:table], sections.first[:format], {}, sections: sections
      )

      refute_includes result, 'Ractor GC scope note:'
    end

    it 'prints the GC per ruby table before the GC summary, with its legend line' do
      ruby_descriptions = { 'master' => 'ruby 4.1.0dev', 'four' => 'ruby 4.0.6', 'three' => 'ruby 3.4.10' }
      sections = [
        {
          title: 'harness-gc',
          table: [['bench', 'master (ms)', 'four (ms)', 'three (ms)'], ['gcbench', '1.0', '2.0', '3.0']],
          format: ['%s', '%s', '%s', '%s'],
          failures: {},
          include_gc: true,
          gc_per_ruby_table: [
            ['bench', 'ruby', 'GC ms/iter', 'controller compacts/iter*'],
            ['gcbench', 'master', '1.000', '0.0'],
            ['gcbench', 'four', '2.000', '0.0'],
            ['gcbench', 'three', '3.000', '0.0']
          ],
          gc_per_ruby_format: ['%s', '%s', '%s', '%s'],
          gc_table: [['bench', 'comparison', 'gc/iter ratio'], ['gcbench', 'four', '0.500'], ['gcbench', 'three', '0.333']],
          gc_format: ['%s', '%s', '%s'],
        },
        {
          title: 'harness',
          table: [['bench', 'master (ms)', 'four (ms)', 'three (ms)'], ['fib', '1.0', '2.0', '3.0']],
          format: ['%s', '%s', '%s', '%s'],
          failures: {},
          include_gc: false,
        }
      ]

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, sections.first[:table], sections.first[:format], {}, sections: sections
      )

      per_ruby_at = result.index("GC per ruby (harness-gc):\n")
      summary_at = result.index("GC summary (harness-gc):\n")
      refute_nil per_ruby_at
      refute_nil summary_at
      assert_operator per_ruby_at, :<, summary_at
      assert_match(/^gcbench\s+master\s+1\.000\s+0\.0$/, result)
      assert_includes result, '- GC per ruby shows the mean GC values per benchmark iteration for each ruby. These values are not ratios. Benchmarks with no GC activity on any ruby are omitted.'
      assert_includes result, 'Do not sum it across workers. GC summary shows master → comparison values. GC per ruby shows the value for each ruby.'
      refute_includes result, 'GC per ruby (harness):'
    end

    it 'explains GC ms/worker in the Ractor scope note when only the GC per ruby table shows it' do
      ruby_descriptions = { 'base' => 'ruby 4.1.0dev', 'exp' => 'ruby 4.1.0dev experiment' }
      sections = [
        {
          title: 'harness-ractor',
          table: [['bench', 'ractors', 'base (ms)', 'exp (ms)'], ['object-new', '2', '1.0', '2.0']],
          format: ['%s', '%s', '%s', '%s'],
          failures: {},
          include_gc: true,
          gc_per_ruby_table: [['bench', 'ractors', 'ruby', 'GC ms/iter (worker sum)', 'GC ms/worker'], ['object-new', '2', 'base', '4.000', '2.000']],
          gc_per_ruby_format: ['%s'] * 5,
          gc_table: [['bench', 'ractors', 'gc/iter ratio'], ['object-new', '2', '2.000']],
          gc_format: ['%s'] * 3,
          gc_scope: 'ractor-local-workload',
        }
      ]

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, sections.first[:table], sections.first[:format], {}, sections: sections
      )

      assert_includes result, "Ractor GC scope note:\n"
      assert_includes result, "GC ms/worker divides each iteration's worker-sum GC time by its sampled worker count, then averages."
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

    it 'prints multiple table sections when provided' do
      ruby_descriptions = { 'ruby' => 'ruby 3.3.0' }
      sections = [
        {
          title: 'harness',
          table: [['bench', 'ruby (ms)'], ['fib', '100.0']],
          format: ['%s', '%.1f'],
          failures: {},
          include_gc: false,
        },
        {
          title: 'harness-ractor',
          table: [['bench', 'ractors', 'ruby (ms)'], ['symbol-name-ractor', '0', '200.0']],
          format: ['%s', '%s', '%.1f'],
          failures: {},
          include_gc: false,
        }
      ]

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, sections.first[:table], sections.first[:format], {}, sections: sections
      )

      assert_includes result, "harness:\n"
      assert_includes result, "harness-ractor:\n"
      assert_includes result, 'fib'
      assert_includes result, 'symbol-name-ractor'
    end

    it 'labels GC summaries by section title' do
      ruby_descriptions = { 'ruby' => 'ruby 3.3.0', 'exp' => 'ruby 3.3.0 exp' }
      sections = [
        {
          title: 'harness-gc',
          table: [['bench', 'ruby (ms)', 'exp (ms)'], ['gcbench', '100.0', '90.0']],
          format: ['%s', '%.1f', '%.1f'],
          failures: {},
          include_gc: true,
          gc_table: [['bench', 'mark/iter ratio'], ['gcbench', '1.100']],
          gc_format: ['%s', '%s'],
        }
      ]

      result = BenchmarkRunner.build_output_text(
        ruby_descriptions, sections.first[:table], sections.first[:format], {}, sections: sections
      )

      assert_includes result, "GC summary (harness-gc):\n"
      assert_includes result, '- GC summary compares ruby → comparison.'
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
