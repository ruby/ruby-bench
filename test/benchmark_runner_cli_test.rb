require_relative 'test_helper'
require_relative '../lib/benchmark_runner/cli'
require_relative '../lib/argument_parser'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'csv'

describe BenchmarkRunner::CLI do
  before do
    @original_env = {}
    ['WARMUP_ITRS', 'MIN_BENCH_ITRS', 'MIN_BENCH_TIME', 'BENCHMARK_QUIET'].each do |key|
      @original_env[key] = ENV[key]
    end

    # Set fast iteration counts for tests
    ENV['WARMUP_ITRS'] = '0'
    ENV['MIN_BENCH_ITRS'] = '1'
    ENV['MIN_BENCH_TIME'] = '0'
    # Suppress benchmark output during tests
    ENV['BENCHMARK_QUIET'] = '1'
  end

  after do
    @original_env.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  # Helper method to create args directly without parsing
  def create_args(overrides = {})
    if RUBY_ENGINE == 'truffleruby'
      executables = { 'truffleruby' => [RbConfig.ruby] }
    else
      executables = { 'interp' => [RbConfig.ruby], 'yjit' => [RbConfig.ruby, '--yjit'] }
    end
    defaults = {
      executables: executables,
      out_path: nil,
      out_override: nil,
      harness: 'default',
      yjit_opts: '',
      categories: [],
      name_filters: [],
      excludes: [],
      rss: false,
      graph: false,
      no_pinning: true,
      turbo: true,
      skip_yjit: false,
      with_pre_init: nil
    }
    ArgumentParser::Args.new(**defaults.merge(overrides))
  end

  describe '.run class method' do
    it 'parses ARGV and runs the CLI end-to-end' do
      Dir.mktmpdir do |tmpdir|
        # Test the full integration: argv array -> parse -> initialize -> run
        output = capture_io do
          BenchmarkRunner::CLI.run([
            '--name_filters=fib',
            '--out_path=' + tmpdir,
            '--once',
            '--no-pinning',
            '--turbo'
          ])
        end.join

        # Verify output contains expected information
        assert_match(/fib/, output, "Output should mention the fib benchmark")
        assert_match(/Total time spent benchmarking:/, output)
        assert_match(/Output:/, output)

        # Verify output files were created
        json_files = Dir.glob(File.join(tmpdir, "output_*.json"))
        assert_equal 1, json_files.size, "Should create exactly one JSON output file"
      end
    end
  end

  describe '#run integration test' do
    it 'runs a simple benchmark end-to-end and produces all output files' do
      Dir.mktmpdir do |tmpdir|
        args = create_args(
          name_filters: ['fib'],
          out_path: tmpdir
        )

        # Run the CLI
        cli = BenchmarkRunner::CLI.new(args)

        # Capture output and run - should not raise errors
        output = capture_io do
          cli.run
        end.join

        # Verify output contains expected information
        assert_match(/fib/, output, "Output should mention the fib benchmark")
        assert_match(/Total time spent benchmarking:/, output)
        assert_match(/Output:/, output)

        # Verify JSON output file was created
        json_files = Dir.glob(File.join(tmpdir, "output_*.json"))
        assert_equal 1, json_files.size, "Should create exactly one JSON output file"

        json_path = json_files.first
        assert File.exist?(json_path), "JSON file should exist"

        # Verify JSON content is valid and contains expected data
        json_data = JSON.parse(File.read(json_path))
        assert json_data.key?('metadata'), "JSON should contain metadata"
        assert json_data.key?('raw_data'), "JSON should contain raw_data"

        # Verify CSV output file was created
        csv_path = json_path.sub('.json', '.csv')
        assert File.exist?(csv_path), "CSV file should exist"

        # Verify CSV content
        csv_data = CSV.read(csv_path)
        assert csv_data.size > 0, "CSV should have content"

        # Verify TXT output file was created
        txt_path = json_path.sub('.json', '.txt')
        assert File.exist?(txt_path), "TXT file should exist"

        # Verify TXT content
        txt_content = File.read(txt_path)
        assert_match(/fib/, txt_content, "TXT should contain benchmark results")
      end
    end

    it 'handles multiple benchmarks with name filters' do
      Dir.mktmpdir do |tmpdir|
        args = create_args(
          name_filters: ['fib', 'respond_to'],
          out_path: tmpdir
        )

        cli = BenchmarkRunner::CLI.new(args)
        output = capture_io { cli.run }.join

        # Check both benchmarks ran
        assert_match(/fib/, output)
        assert_match(/respond_to/, output)

        # Check output files were created
        json_files = Dir.glob(File.join(tmpdir, "*.json"))
        assert_equal 1, json_files.size

        json_data = JSON.parse(File.read(json_files.first))
        raw_data = json_data['raw_data']

        # Verify data contains results for both benchmarks
        assert raw_data.values.any? { |data| data.key?('fib') }
        assert raw_data.values.any? { |data| data.key?('respond_to') }
      end
    end

    it 'respects output path override' do
      Dir.mktmpdir do |tmpdir|
        custom_name = File.join(tmpdir, 'custom_output')

        args = create_args(
          name_filters: ['fib'],
          out_path: tmpdir,
          out_override: custom_name
        )

        cli = BenchmarkRunner::CLI.new(args)
        capture_io { cli.run }

        # Check that custom-named files were created
        assert File.exist?(custom_name + '.json'), "Custom JSON file should exist"
        assert File.exist?(custom_name + '.csv'), "Custom CSV file should exist"
        assert File.exist?(custom_name + '.txt'), "Custom TXT file should exist"
      end
    end

    it 'compares different ruby executables' do
      skip "Requires actual ruby installations" unless ENV['RUN_INTEGRATION_TESTS']

      Dir.mktmpdir do |tmpdir|
        ruby_path = RbConfig.ruby

        args = create_args(
          executables: { 'test1' => [ruby_path], 'test2' => [ruby_path] },
          name_filters: ['fib'],
          out_path: tmpdir
        )

        cli = BenchmarkRunner::CLI.new(args)
        output = capture_io { cli.run }.join

        # Should show comparison between two executables
        assert_match(/test1/, output)
        assert_match(/test2/, output)

        json_files = Dir.glob(File.join(tmpdir, "*.json"))
        json_data = JSON.parse(File.read(json_files.first))

        # Both executables should be in metadata
        assert json_data['metadata'].key?('test1')
        assert json_data['metadata'].key?('test2')

        # Both should have raw data
        assert json_data['raw_data'].key?('test1')
        assert json_data['raw_data'].key?('test2')
      end
    end

    it 'handles benchmark with category filter' do
      Dir.mktmpdir do |tmpdir|
        args = create_args(
          categories: ['micro'],
          name_filters: ['fib'],
          out_path: tmpdir
        )

        cli = BenchmarkRunner::CLI.new(args)
        output = capture_io { cli.run }.join

        # Should run successfully
        assert_match(/Total time spent benchmarking:/, output)

        # Output files should exist
        json_files = Dir.glob(File.join(tmpdir, "*.json"))
        assert_equal 1, json_files.size
      end
    end

    it 'creates sequential output files when no override specified' do
      Dir.mktmpdir do |tmpdir|
        # Run first benchmark
        args1 = create_args(
          name_filters: ['fib'],
          out_path: tmpdir
        )
        cli1 = BenchmarkRunner::CLI.new(args1)
        capture_io { cli1.run }

        # Run second benchmark
        args2 = create_args(
          name_filters: ['respond_to'],
          out_path: tmpdir
        )
        cli2 = BenchmarkRunner::CLI.new(args2)
        capture_io { cli2.run }

        # Should have two sets of output files
        json_files = Dir.glob(File.join(tmpdir, "output_*.json")).sort
        assert_equal 2, json_files.size
        assert_match(/output_001\.json$/, json_files[0])
        assert_match(/output_002\.json$/, json_files[1])
      end
    end

    it 'includes RSS data when --rss flag is set' do
      Dir.mktmpdir do |tmpdir|
        args = create_args(
          name_filters: ['fib'],
          out_path: tmpdir,
          rss: true
        )

        cli = BenchmarkRunner::CLI.new(args)
        capture_io { cli.run }

        # Output should reference RSS
        txt_files = Dir.glob(File.join(tmpdir, "*.txt"))
        txt_content = File.read(txt_files.first)
        assert_match(/RSS/, txt_content, "Output should include RSS information")
      end
    end

    it 'handles no matching benchmarks gracefully' do
      Dir.mktmpdir do |tmpdir|
        args = create_args(
          name_filters: ['nonexistent_benchmark_xyz'],
          out_path: tmpdir
        )

        cli = BenchmarkRunner::CLI.new(args)

        # Should run without error but produce empty results
        capture_io { cli.run }

        # Should still create output files
        json_files = Dir.glob(File.join(tmpdir, "*.json"))
        assert_equal 1, json_files.size
      end
    end

    it 'can be instantiated and have args accessed' do
      args = create_args(name_filters: ['fib'])
      cli = BenchmarkRunner::CLI.new(args)

      assert_equal args, cli.args
      assert_equal ['fib'], cli.args.name_filters
    end

    it 'prints benchmark timing information' do
      Dir.mktmpdir do |tmpdir|
        args = create_args(
          name_filters: ['fib'],
          out_path: tmpdir
        )

        cli = BenchmarkRunner::CLI.new(args)
        output = capture_io { cli.run }.join

        # Should show timing
        assert_match(/Total time spent benchmarking: \d+s/, output)
      end
    end

    it 'creates output directory if it does not exist' do
      Dir.mktmpdir do |parent_tmpdir|
        nested_dir = File.join(parent_tmpdir, 'nested', 'output', 'dir')
        refute Dir.exist?(nested_dir), "Directory should not exist yet"

        args = create_args(
          name_filters: ['fib'],
          out_path: nested_dir
        )

        cli = BenchmarkRunner::CLI.new(args)
        capture_io { cli.run }

        assert Dir.exist?(nested_dir), "Directory should be created"

        # Verify files were created in the new directory
        json_files = Dir.glob(File.join(nested_dir, "*.json"))
        assert_equal 1, json_files.size
      end
    end
  end
end
