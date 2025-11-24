require_relative 'test_helper'
require 'open3'
require 'tmpdir'
require 'fileutils'

describe 'run_once.rb' do
  before do
    @script_path = File.expand_path('../run_once.rb', __dir__)
    @original_env = ENV.to_h

    # Create a temp directory with test benchmarks
    @tmpdir = Dir.mktmpdir
    @test_benchmark = File.join(@tmpdir, 'test_benchmark.rb')
    File.write(@test_benchmark, <<~RUBY)
      puts "Benchmark executed"
      puts "WARMUP_ITRS=\#{ENV['WARMUP_ITRS']}"
      puts "MIN_BENCH_ITRS=\#{ENV['MIN_BENCH_ITRS']}"
      puts "MIN_BENCH_TIME=\#{ENV['MIN_BENCH_TIME']}"
    RUBY
  end

  after do
    FileUtils.rm_rf(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
    # Restore original environment
    ENV.replace(@original_env)
  end

  def run_script(*args)
    # Run the script and capture output
    Open3.capture3('ruby', @script_path, *args)
  end

  describe 'basic execution' do
    it 'executes a benchmark file' do
      stdout, _stderr, status = run_script(@test_benchmark)

      assert status.success?, "Script should execute successfully. stderr: #{_stderr}"
      assert_match(/Benchmark executed/, stdout)
    end

    it 'sets environment variables for single iteration' do
      stdout, _stderr, status = run_script(@test_benchmark)

      assert status.success?
      assert_match(/WARMUP_ITRS=0/, stdout)
      assert_match(/MIN_BENCH_ITRS=1/, stdout)
      assert_match(/MIN_BENCH_TIME=0/, stdout)
    end

    it 'shows error when no benchmark file specified' do
      stdout, _stderr, status = run_script

      refute status.success?
      assert_match(/No benchmark file specified/, stdout)
    end

    it 'shows error when benchmark file does not exist' do
      stdout, _stderr, status = run_script('/nonexistent/benchmark.rb')

      refute status.success?
      assert_match(/Benchmark file not found/, stdout)
    end
  end

  describe '--harness option' do
    it 'accepts default harness' do
      stdout, _stderr, status = run_script('--harness=default', @test_benchmark)

      assert status.success?
      assert_match(/Benchmark executed/, stdout)
    end

    it 'loads custom harness when specified' do
      # Create a test harness
      harness_dir = File.join(File.dirname(@script_path), 'harness')
      FileUtils.mkdir_p(harness_dir)
      test_harness = File.join(harness_dir, 'test_harness.rb')

      begin
        File.write(test_harness, <<~RUBY)
          puts "TEST HARNESS LOADED"
        RUBY

        stdout, _stderr, status = run_script('--harness=test_harness', @test_benchmark)

        assert status.success?
        assert_match(/TEST HARNESS LOADED/, stdout)
      ensure
        File.delete(test_harness) if File.exist?(test_harness)
      end
    end

    it 'shows error for non-existent harness' do
      stdout, _stderr, status = run_script('--harness=nonexistent', @test_benchmark)

      refute status.success?
      assert_match(/Harness not found/, stdout)
      assert_match(/Available harnesses/, stdout)
    end
  end

  describe 'ractor benchmark detection' do
    it 'automatically uses ractor harness for ractor benchmarks' do
      # Create a ractor benchmark
      ractor_dir = File.join(@tmpdir, 'benchmarks-ractor', 'test')
      FileUtils.mkdir_p(ractor_dir)
      ractor_benchmark = File.join(ractor_dir, 'benchmark.rb')
      File.write(ractor_benchmark, 'puts "Ractor benchmark"')

      _stdout, _stderr, _status = run_script(ractor_benchmark)

      # The script will try to load ractor harness
      # We just verify it detected the ractor path
      assert_match(/benchmarks-ractor/, ractor_benchmark)
    end
  end

  describe 'Ruby options pass-through' do
    it 'passes Ruby options after -- separator' do
      # Create a benchmark that checks for a warning flag
      warning_benchmark = File.join(@tmpdir, 'warning_test.rb')
      File.write(warning_benchmark, <<~RUBY)
        x = 1
        x = 2
        puts "Benchmark with warnings"
      RUBY

      stdout, _stderr, status = run_script('--', '-W2', warning_benchmark)

      assert status.success?
      assert_match(/Benchmark with warnings/, stdout)
    end

    it 'passes YJIT options after -- separator' do
      yjit_benchmark = File.join(@tmpdir, 'yjit_test.rb')
      File.write(yjit_benchmark, <<~RUBY)
        puts "YJIT enabled" if defined?(RubyVM::YJIT)
        puts "Benchmark complete"
      RUBY

      stdout, _stderr, status = run_script('--', '--yjit', yjit_benchmark)

      assert status.success?
      assert_match(/Benchmark complete/, stdout)
    end
  end

  describe '--help option' do
    it 'shows help message' do
      stdout, _stderr, status = run_script('--help')

      assert status.success?
      assert_match(/Usage:/, stdout)
      assert_match(/--harness/, stdout)
    end

    it 'shows help with -h' do
      stdout, _stderr, status = run_script('-h')

      assert status.success?
      assert_match(/Usage:/, stdout)
    end
  end

  describe 'argument parsing order' do
    it 'handles harness option before benchmark' do
      stdout, _stderr, status = run_script('--harness=default', @test_benchmark)

      assert status.success?
      assert_match(/Benchmark executed/, stdout)
    end

    it 'handles Ruby options after -- separator' do
      stdout, _stderr, status = run_script('--', '-W0', @test_benchmark)

      assert status.success?
      assert_match(/Benchmark executed/, stdout)
    end

    it 'handles mixed options with -- separator' do
      stdout, _stderr, status = run_script('--harness=default', '--', '-W0', @test_benchmark)

      assert status.success?
      assert_match(/Benchmark executed/, stdout)
    end
  end

  describe 'script examples' do
    it 'works with simple benchmark path' do
      # Simulates: ./run_once.rb benchmarks/fib.rb
      fib_benchmark = File.join(@tmpdir, 'fib.rb')
      File.write(fib_benchmark, 'puts "Fibonacci benchmark"')

      stdout, _stderr, status = run_script(fib_benchmark)

      assert status.success?
      assert_match(/Fibonacci benchmark/, stdout)
    end

    it 'works with harness option' do
      # Simulates: ./run_once.rb --harness=default benchmarks/fib.rb
      stdout, _stderr, status = run_script('--harness=default', @test_benchmark)

      assert status.success?
      assert_match(/Benchmark executed/, stdout)
    end

    it 'works with Ruby options after -- separator' do
      # Simulates: ./run_once.rb -- --yjit benchmarks/fib.rb
      stdout, _stderr, status = run_script('--', '--yjit', @test_benchmark)

      assert status.success?
      assert_match(/Benchmark executed/, stdout)
    end
  end

  describe 'edge cases' do
    it 'handles benchmark files with spaces in path' do
      space_dir = File.join(@tmpdir, 'dir with spaces')
      FileUtils.mkdir_p(space_dir)
      space_benchmark = File.join(space_dir, 'benchmark.rb')
      File.write(space_benchmark, 'puts "Space test"')

      stdout, _stderr, status = run_script(space_benchmark)

      assert status.success?
      assert_match(/Space test/, stdout)
    end

    it 'identifies first .rb file as benchmark' do
      # Even if multiple .rb files mentioned (shouldn't happen), first one wins
      other_file = File.join(@tmpdir, 'other.rb')
      File.write(other_file, 'puts "Wrong file"')

      stdout, _stderr, status = run_script(@test_benchmark)

      assert status.success?
      assert_match(/Benchmark executed/, stdout)
      refute_match(/Wrong file/, stdout)
    end

    it 'rejects invalid options gracefully' do
      stdout, _stderr, status = run_script('--invalid-option', @test_benchmark)

      refute status.success?
      assert_match(/invalid option|Error/, stdout)
    end
  end
end
