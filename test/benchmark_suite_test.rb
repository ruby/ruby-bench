require_relative 'test_helper'
require_relative '../lib/benchmark_suite'
require 'tempfile'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'

describe BenchmarkSuite do
  before do
    ENV.delete('RESULT_JSON_PATH')
    @original_dir = Dir.pwd
    @temp_dir = Dir.mktmpdir
    Dir.chdir(@temp_dir)

    # Create mock benchmarks directory structure
    FileUtils.mkdir_p('benchmarks')
    FileUtils.mkdir_p('harness')

    # Create a simple benchmark file
    File.write('benchmarks/simple.rb', <<~RUBY)
      require 'json'
      result = {
        'warmup' => [0.001],
        'bench' => [0.001, 0.0009, 0.0011],
        'rss' => 10485760
      }
      File.write(ENV['RESULT_JSON_PATH'], JSON.generate(result))
    RUBY

    # Create benchmarks metadata
    @metadata = {
      'simple' => { 'category' => 'micro' },
      'fib' => { 'category' => 'micro' }
    }
    File.write('benchmarks.yml', YAML.dump(@metadata))

    @out_path = File.join(@temp_dir, 'output')
    FileUtils.mkdir_p(@out_path)
  end

  after do
    ENV.delete('RESULT_JSON_PATH')
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(@temp_dir)
  end

  describe '#initialize' do
    it 'sets all required attributes' do
      suite = BenchmarkSuite.new(
        categories: ['micro'],
        name_filters: [],
        out_path: @out_path,
        harness: 'harness'
      )

      assert_equal ['micro'], suite.categories
      assert_equal [], suite.name_filters
      assert_equal @out_path, suite.out_path
      assert_equal 'harness', suite.harness
      assert_nil suite.pre_init
      assert_equal false, suite.no_pinning
    end

    it 'accepts optional parameters' do
      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: [],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      assert_equal true, suite.no_pinning
    end

    it 'sets bench_dir to BENCHMARKS_DIR' do
      suite = BenchmarkSuite.new(
        categories: ['micro'],
        name_filters: [],
        out_path: @out_path,
        harness: 'harness'
      )

      assert_equal 'benchmarks', suite.bench_dir
      assert_equal 'harness', suite.harness
      assert_equal ['micro'], suite.categories
    end

    it 'keeps bench_dir as BENCHMARKS_DIR when ractor category is used' do
      suite = BenchmarkSuite.new(
        categories: ['ractor'],
        name_filters: [],
        out_path: @out_path,
        harness: 'harness'
      )

      assert_equal 'benchmarks', suite.bench_dir
      assert_equal 'harness', suite.harness
      assert_equal ['ractor'], suite.categories
    end

    it 'tracks harness_explicit flag' do
      suite_explicit = BenchmarkSuite.new(
        categories: [],
        name_filters: [],
        out_path: @out_path,
        harness: 'custom-harness',
        harness_explicit: true
      )
      assert_equal true, suite_explicit.harness_explicit

      suite_auto = BenchmarkSuite.new(
        categories: [],
        name_filters: [],
        out_path: @out_path,
        harness: 'harness-ractor'
      )
      assert_equal false, suite_auto.harness_explicit
    end
  end

  describe '#benchmark_harness_for' do
    before do
      @metadata_with_harness = {
        'simple' => { 'category' => 'micro' },
        'custom_harness_bench' => { 'category' => 'other', 'default_harness' => 'harness' }
      }
      File.write('benchmarks.yml', YAML.dump(@metadata_with_harness))
    end

    it 'returns default_harness when set and harness not explicit' do
      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: [],
        out_path: @out_path,
        harness: 'harness-ractor',
        harness_explicit: false
      )

      assert_equal 'harness', suite.send(:benchmark_harness_for, 'custom_harness_bench')
      assert_equal 'harness-ractor', suite.send(:benchmark_harness_for, 'simple')
    end

    it 'ignores default_harness when harness is explicit' do
      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: [],
        out_path: @out_path,
        harness: 'custom-harness',
        harness_explicit: true
      )

      assert_equal 'custom-harness', suite.send(:benchmark_harness_for, 'custom_harness_bench')
      assert_equal 'custom-harness', suite.send(:benchmark_harness_for, 'simple')
    end
  end

  describe '#ractor_category_run?' do
    it 'returns true for ractor category' do
      suite = BenchmarkSuite.new(
        categories: ['ractor'],
        name_filters: [],
        out_path: @out_path,
        harness: 'harness-ractor'
      )

      assert_equal true, suite.send(:ractor_category_run?)
    end

    it 'returns false for other categories' do
      suite = BenchmarkSuite.new(
        categories: ['micro'],
        name_filters: [],
        out_path: @out_path,
        harness: 'harness'
      )

      assert_equal false, suite.send(:ractor_category_run?)
    end
  end

  describe '#run' do
    it 'returns bench_data and bench_failures as a tuple' do
      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['simple'],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      result = nil
      capture_io do
        result = suite.run(ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      assert_instance_of Array, result
      assert_equal 2, result.length

      bench_data, bench_failures = result
      assert_instance_of Hash, bench_data
      assert_instance_of Hash, bench_failures
    end

    it 'runs matching benchmarks and collects results' do
      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['simple'],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      bench_data, bench_failures = nil
      capture_io do
        bench_data, bench_failures = suite.run(ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      assert_includes bench_data, 'simple'
      assert_includes bench_data['simple'], 'warmup'
      assert_includes bench_data['simple'], 'bench'
      assert_includes bench_data['simple'], 'rss'
      assert_includes bench_data['simple'], 'command_line'

      assert_empty bench_failures
    end

    it 'prints progress messages while running' do
      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['simple'],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      output = capture_io do
        suite.run(ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      assert_includes output[0], 'Running benchmark "simple"'
    end

    it 'records failures when benchmark script fails' do
      # Create a failing benchmark
      File.write('benchmarks/failing.rb', <<~RUBY)
        exit(1)
      RUBY

      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['failing'],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      bench_data, bench_failures = nil
      capture_io do
        bench_data, bench_failures = suite.run(ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      assert_empty bench_data
      assert_includes bench_failures, 'failing'
      assert_equal 1, bench_failures['failing']
    end

    it 'handles benchmarks in subdirectories' do
      # Create a benchmark in a subdirectory
      FileUtils.mkdir_p('benchmarks/subdir')
      File.write('benchmarks/subdir/benchmark.rb', <<~RUBY)
        require 'json'
        result = {
          'warmup' => [0.001],
          'bench' => [0.001],
          'rss' => 10485760
        }
        File.write(ENV['RESULT_JSON_PATH'], JSON.generate(result))
      RUBY

      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['subdir'],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      bench_data, bench_failures = nil
      capture_io do
        bench_data, bench_failures = suite.run(ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      assert_includes bench_data, 'subdir'
      assert_empty bench_failures
    end

    it 'handles ractor category with ractor benchmarks' do
      # Create a ractor benchmark
      File.write('benchmarks/ractor_test.rb', <<~RUBY)
        require 'json'
        result = {
          'warmup' => [0.001],
          'bench' => [0.001],
          'rss' => 10485760
        }
        File.write(ENV['RESULT_JSON_PATH'], JSON.generate(result))
      RUBY

      metadata = {
        'ractor_test' => { 'category' => 'other', 'ractor' => true },
        'simple' => { 'category' => 'micro' }
      }
      File.write('benchmarks.yml', YAML.dump(metadata))

      suite = BenchmarkSuite.new(
        categories: ['ractor'],
        name_filters: [],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      bench_data, bench_failures = nil
      capture_io do
        bench_data, bench_failures = suite.run(ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      # Should only include ractor benchmarks when ractor category specified
      assert_includes bench_data, 'ractor_test'
      refute_includes bench_data, 'simple'
      assert_empty bench_failures
    end

    it 'expands pre_init when provided' do
      # Create a pre_init file
      pre_init_file = File.join(@temp_dir, 'pre_init.rb')
      File.write(pre_init_file, "# Pre-initialization code\n")

      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['simple'],
        out_path: @out_path,
        harness: 'harness',
        pre_init: pre_init_file,
        no_pinning: true
      )

      assert_instance_of Array, suite.pre_init
      assert_equal 4, suite.pre_init.length
      assert_equal '-I', suite.pre_init[0]
      assert_equal @temp_dir, suite.pre_init[1].to_s
      assert_equal '-r', suite.pre_init[2]
      assert_equal 'pre_init', suite.pre_init[3].to_s
    end

    it 'handles pre_init with different file extensions' do
      # Create a pre_init file with a different name
      pre_init_file = File.join(@temp_dir, 'my_config.rb')
      File.write(pre_init_file, "# Config code\n")

      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['simple'],
        out_path: @out_path,
        harness: 'harness',
        pre_init: pre_init_file,
        no_pinning: true
      )

      # Should extract filename without extension
      assert_equal 'my_config', suite.pre_init[3].to_s
    end

    it 'handles pre_init in nested directories' do
      # Create a pre_init file in nested directory
      subdir = File.join(@temp_dir, 'config', 'initializers')
      FileUtils.mkdir_p(subdir)
      pre_init_file = File.join(subdir, 'setup.rb')
      File.write(pre_init_file, "# Setup code\n")

      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['simple'],
        out_path: @out_path,
        harness: 'harness',
        pre_init: pre_init_file,
        no_pinning: true
      )

      # Should use the nested directory as load path
      assert_equal subdir, suite.pre_init[1].to_s
      assert_equal 'setup', suite.pre_init[3].to_s
    end

    it 'exits when pre_init file does not exist' do
      output = capture_io do
        assert_raises(SystemExit) do
          BenchmarkSuite.new(
            categories: [],
            name_filters: ['simple'],
            out_path: @out_path,
            harness: 'harness',
            pre_init: '/nonexistent/file.rb',
            no_pinning: true
          )
        end
      end
      assert_includes output[0], '--with-pre-init called with non-existent file!'
    end

    it 'exits when pre_init path is a directory' do
      output = capture_io do
        assert_raises(SystemExit) do
          BenchmarkSuite.new(
            categories: [],
            name_filters: ['simple'],
            out_path: @out_path,
            harness: 'harness',
            pre_init: @temp_dir,
            no_pinning: true
          )
        end
      end
      assert_includes output[0], '--with-pre-init called with a directory'
    end

    it 'stores command_line in benchmark results' do
      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['simple'],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      bench_data, _ = nil
      capture_io do
        bench_data, _ = suite.run(ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      assert_includes bench_data['simple'], 'command_line'
      assert_instance_of String, bench_data['simple']['command_line']
      assert_includes bench_data['simple']['command_line'], 'simple.rb'
    end

    it 'cleans up temporary JSON files after successful run' do
      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['simple'],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      capture_io do
        suite.run(ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      # Temporary files should be cleaned up
      temp_files = Dir.glob(File.join(@out_path, 'temp*.json'))
      assert_empty temp_files
    end

    it 'uses RESULT_JSON_PATH env var when set and preserves the file' do
      custom_json_path = File.join(@out_path, 'custom_result.json')
      ENV['RESULT_JSON_PATH'] = custom_json_path

      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['simple'],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      capture_io do
        suite.run(ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      assert File.exist?(custom_json_path), "Expected #{custom_json_path} to exist but it was deleted"
      result = JSON.parse(File.read(custom_json_path))
      assert_includes result, 'bench'
    ensure
      ENV.delete('RESULT_JSON_PATH')
      FileUtils.rm_f(custom_json_path)
    end

    it 'filters benchmarks by name_filters' do
      # Create multiple benchmarks
      File.write('benchmarks/bench_a.rb', <<~RUBY)
        require 'json'
        result = { 'warmup' => [0.001], 'bench' => [0.001], 'rss' => 10485760 }
        File.write(ENV['RESULT_JSON_PATH'], JSON.generate(result))
      RUBY

      File.write('benchmarks/bench_b.rb', <<~RUBY)
        require 'json'
        result = { 'warmup' => [0.001], 'bench' => [0.001], 'rss' => 10485760 }
        File.write(ENV['RESULT_JSON_PATH'], JSON.generate(result))
      RUBY

      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['bench_a'],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      bench_data = nil
      capture_io do
        bench_data, _ = suite.run(ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      assert_includes bench_data, 'bench_a'
      refute_includes bench_data, 'bench_b'
    end
  end

  describe '#benchmarks' do
    it 'returns discovered benchmark entries' do
      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['simple'],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      entries = suite.benchmarks
      assert_instance_of Array, entries
      assert_equal 1, entries.length
      assert_equal 'simple', entries.first.name
    end

    it 'memoizes the result' do
      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['simple'],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      assert_same suite.benchmarks, suite.benchmarks
    end
  end

  describe '#run_benchmark' do
    it 'returns data hash on success' do
      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['simple'],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      entry = suite.benchmarks.first
      result = nil
      capture_io do
        result = suite.run_benchmark(entry, ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      assert_equal 'simple', result[:name]
      assert_instance_of Hash, result[:data]
      assert_includes result[:data], 'warmup'
      assert_includes result[:data], 'bench'
      assert_includes result[:data], 'rss'
      assert_nil result[:failure]
    end

    it 'returns failure hash on error' do
      File.write('benchmarks/failing.rb', "exit(1)\n")

      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['failing'],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      entry = suite.benchmarks.first
      result = nil
      capture_io do
        result = suite.run_benchmark(entry, ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      assert_equal 'failing', result[:name]
      assert_nil result[:data]
      assert_equal 1, result[:failure]
    end

    it 'produces same data as run for the same benchmark' do
      suite = BenchmarkSuite.new(
        categories: [],
        name_filters: ['simple'],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      entry = suite.benchmarks.first
      single_result = nil
      capture_io do
        single_result = suite.run_benchmark(entry, ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      run_data = nil
      capture_io do
        run_data, _ = suite.run(ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      assert_equal run_data['simple'].keys.sort, single_result[:data].keys.sort
    end
  end

  describe 'integration with BenchmarkFilter' do
    it 'uses BenchmarkFilter to match benchmarks' do
      # Create benchmarks with different categories
      File.write('benchmarks/micro_bench.rb', <<~RUBY)
        require 'json'
        result = { 'warmup' => [0.001], 'bench' => [0.001], 'rss' => 10485760 }
        File.write(ENV['RESULT_JSON_PATH'], JSON.generate(result))
      RUBY

      metadata = {
        'micro_bench' => { 'category' => 'micro' },
        'simple' => { 'category' => 'other' }
      }
      File.write('benchmarks.yml', YAML.dump(metadata))

      suite = BenchmarkSuite.new(
        categories: ['micro'],
        name_filters: [],
        out_path: @out_path,
        harness: 'harness',
        no_pinning: true
      )

      bench_data = nil
      capture_io do
        bench_data, _ = suite.run(ruby: [RbConfig.ruby], ruby_description: 'ruby 3.2.0')
      end

      # Should only include micro category benchmarks
      assert_includes bench_data, 'micro_bench'
      refute_includes bench_data, 'simple'
    end
  end
end
