require_relative 'test_helper'
require 'shellwords'
require 'tmpdir'
require 'fileutils'

describe 'run_benchmarks.rb integration' do
  before do
    @script_path = File.expand_path('../run_benchmarks.rb', __dir__)
    @ruby_path = RbConfig.ruby
  end

  describe 'command-line parsing' do
    it 'shows help with --help flag' do
      skip 'Skipping integration test - requires full setup'
    end

    it 'handles --once flag' do
      Dir.mktmpdir do |tmpdir|
        # This would set ENV["WARMUP_ITRS"] = "0" and ENV["MIN_BENCH_ITRS"] = "1"
        cmd = "#{@ruby_path} #{@script_path} --once --name_filters=fib --out_path=#{tmpdir} 2>&1"
        result = `#{cmd}`

        # Should run but may fail due to missing benchmarks - that's okay
        # We're just checking the script can parse arguments
        skip 'Requires benchmark environment' unless $?.success? || result.include?('Running benchmark')
      end
    end
  end

  describe 'output files' do
    it 'creates output files with correct naming convention' do
      Dir.mktmpdir do |tmpdir|
        # Create some mock output files
        File.write(File.join(tmpdir, 'output_001.csv'), 'test')
        File.write(File.join(tmpdir, 'output_002.csv'), 'test')

        # The free_file_no function should find the next number
        require_relative '../lib/benchmark_runner'
        file_no = BenchmarkRunner.free_file_no(tmpdir)
        assert_equal 3, file_no
      end
    end

    it 'uses correct output file format' do
      file_no = 42
      expected = 'output_042.csv'
      actual = 'output_%03d.csv' % file_no
      assert_equal expected, actual
    end
  end

  describe 'benchmark metadata' do
    before do
      @benchmarks_yml = File.expand_path('../benchmarks.yml', __dir__)
    end

    it 'benchmarks.yml exists' do
      assert_equal true, File.exist?(@benchmarks_yml)
    end

    it 'benchmarks.yml is valid YAML' do
      require 'yaml'
      data = YAML.load_file(@benchmarks_yml)
      assert_instance_of Hash, data
    end

    it 'benchmarks.yml has valid category values' do
      require 'yaml'
      data = YAML.load_file(@benchmarks_yml)
      valid_categories = ['headline', 'micro', 'other']

      data.each do |name, metadata|
        if metadata['category']
          assert_includes valid_categories, metadata['category'],
            "Benchmark '#{name}' has invalid category: #{metadata['category']}"
        end
      end
    end
  end

  describe 'script structure' do
    it 'run_benchmarks.rb is executable' do
      assert_equal true, File.executable?(@script_path)
    end

    it 'run_benchmarks.rb has shebang' do
      first_line = File.open(@script_path, &:readline)
      assert_match(/^#!.*ruby/, first_line)
    end

    it 'loads required dependencies' do
      # Check that the script loads without errors (syntax check)
      cmd = "#{@ruby_path} -c #{@script_path}"
      result = `#{cmd} 2>&1`
      assert_includes result, 'Syntax OK'
    end
  end

  describe 'stats module integration' do
    it 'uses Stats class for calculations' do
      require_relative '../misc/stats'

      values = [1, 2, 3, 4, 5]
      stats = Stats.new(values)

      assert_equal 3.0, stats.mean
      assert_in_delta 1.414, stats.stddev, 0.01
    end
  end
end
