require_relative 'test_helper'
require 'shellwords'
require 'tmpdir'
require 'fileutils'

# Tests for run_benchmarks.rb script integration
# This complements benchmark_runner_cli_test.rb by testing:
# - The script itself as a subprocess
# - Script structure and permissions
# - Benchmark metadata validation
describe 'run_benchmarks.rb integration' do
  before do
    @script_path = File.expand_path('../run_benchmarks.rb', __dir__)
    @ruby_path = RbConfig.ruby
    @original_env = ENV['BENCHMARK_QUIET']
  end

  after do
    if @original_env.nil?
      ENV.delete('BENCHMARK_QUIET')
    else
      ENV['BENCHMARK_QUIET'] = @original_env
    end
  end

  describe 'script execution as subprocess' do
    it 'runs successfully as a standalone script' do
      Dir.mktmpdir do |tmpdir|
        # Test that the script can be invoked as a subprocess
        ENV['BENCHMARK_QUIET'] = '1'
        cmd = "#{@ruby_path} #{@script_path} --once --name_filters=fib --out_path=#{tmpdir} --no-pinning --turbo 2>&1"
        result = `#{cmd}`
        exit_status = $?.exitstatus

        assert_equal 0, exit_status, "Script should exit successfully. Output: #{result}"
        assert_match(/Total time spent benchmarking:/, result)
      end
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
      valid_categories = ['headline', 'micro', 'thread', 'other']

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
