require_relative 'test_helper'
require 'open3'
require 'tmpdir'
require 'json'
require 'rbconfig'
require 'fileutils'

class CallgrindHarnessTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  # Pretend to be a Linux process running under Callgrind (or not).
  def fake_platform(host_os: 'linux', comm: 'callgrind-amd64')
    <<~STUB
      require 'rbconfig'
      RbConfig::CONFIG['host_os'] = #{host_os.inspect}
      File.singleton_class.prepend(Module.new do
        def read(path, *args, **kwargs)
          path == '/proc/self/comm' ? #{(comm + "\n").inspect} : super
        end
      end)
    STUB
  end

  def load_harness(**platform)
    script = fake_platform(**platform) + "require #{File.join(ROOT, 'harness/callgrind').inspect}"
    env = { 'RUBYOPT' => nil, 'BUNDLE_GEMFILE' => nil, 'BUNDLER_SETUP' => nil }
    Open3.capture3(env, RbConfig.ruby, '-e', script, chdir: ROOT)
  end

  def run_harness(env = {}, fail_at: nil)
    Dir.mktmpdir do |dir|
      # Fake a global gem so tests do not install a native extension.
      gem_lib = File.join(dir, 'gems', 'lib')
      FileUtils.mkdir_p(gem_lib)
      # Model Callgrind's counters: client requests cost 1 Ir and the workload
      # charges its own, but only while instrumented. Dumps write the real
      # "<out file>.<part>" layout (as resolved by the harness) and reset the
      # counter.
      File.write(File.join(gem_lib, 'valgrind.rb'), <<~RUBY)
        module Valgrind
          @instrumented = true
          @ir = 0
          @part = 0
          def self.charge(ir); @ir += ir if @instrumented; end
          def self.callgrind_stop_instrumentation; @instrumented = false; $events << 'stop'; end
          def self.callgrind_start_instrumentation; @instrumented = true; charge(1); $events << 'start'; end
          def self.callgrind_zero_stats; @ir = 0; charge(1); $events << 'zero'; end
          def self.callgrind_dump_stats(name)
            charge(1)
            $events << "dump:" + name
            @part += 1
            File.write(ENV.fetch('FAKE_DUMP_PREFIX', CALLGRIND_OUT_FILE) + ".\#{@part}", "events: Ir\nsummary: 1\ntotals: \#{@ir}\n")
            @ir = 0
          end
        end
      RUBY
      script = fake_platform + <<~RUBY
        require 'json'
        $events = []
        require #{File.join(ROOT, 'lib/harness/extra').inspect}
        def ensure_global_gem(name)
          raise 'wrong gem' unless name == 'valgrind'
          $LOAD_PATH << #{gem_lib.inspect}
        end
        require #{File.join(ROOT, 'harness/callgrind').inspect}
        def return_results(warmup, bench, metrics:, primary_metric:)
          raise 'wrong metric' unless primary_metric == 'instructions' && metrics.keys == ['instructions']
          $events << ['results', warmup.size, bench.size, metrics['instructions']['bench']]
        end
        calls = 0
        begin
          run_benchmark(3, ignored_keyword: true) do
            calls += 1
            $events << 'work'
            Valgrind.charge(calls * 10)
            raise 'workload failed' if calls == #{fail_at.inspect}
          end
        rescue => e
          $events << e.message
        end
        puts JSON.generate($events)
      RUBY
      clean_env = {
        'RUBYOPT' => nil, 'BUNDLE_GEMFILE' => nil, 'BUNDLER_SETUP' => nil,
        'WARMUP_ITRS' => '2', 'MIN_BENCH_ITRS' => nil,
        'RESULT_JSON_PATH' => File.join(dir, 'results.json'),
        'VALGRIND_OPTS' => nil, 'FAKE_DUMP_PREFIX' => nil
      }.merge(env.transform_values { |v| v&.gsub('DIR', dir) })
      out, err, status = Open3.capture3(clean_env, RbConfig.ruby, '-I', dir, '-e', script, chdir: dir)
      assert status.success?, "#{out}\n#{err}"
      yield dir if block_given?
      JSON.parse(out.lines.last)
    end
  end

  def measured(i)
    ['zero', 'work', "dump:-e itr #{i}"]
  end

  def test_profiles_hint_iterations_after_warmup
    assert_equal ['stop', 'stop', 'work', 'work', 'start',
                  *measured(0), *measured(1), *measured(2),
                  'stop', ['results', 2, 3, [32, 42, 52]]], run_harness
  end

  def test_iteration_overrides_and_zero_warmup
    assert_equal ['stop', 'stop', 'start', *measured(0), 'stop', ['results', 0, 1, [12]]],
                 run_harness({ 'WARMUP_ITRS' => '0', 'MIN_BENCH_ITRS' => '1' })
  end

  def test_failure_stops_collecting_and_dumps_without_results
    assert_equal ['stop', 'stop', 'work', 'work', 'start', *measured(0),
                  'stop', 'workload failed'], run_harness({}, fail_at: 3)
  end

  def test_warmup_failure_never_starts_profiling
    assert_equal ['stop', 'stop', 'work', 'workload failed'], run_harness({}, fail_at: 1)
  end

  def test_invalid_counts_fail_before_workload
    assert_equal ['stop', 'MIN_BENCH_ITRS must be positive'], run_harness({ 'MIN_BENCH_ITRS' => '0' })
    assert_equal ['stop', 'WARMUP_ITRS must be non-negative'], run_harness({ 'WARMUP_ITRS' => '-1' })
    events = run_harness({ 'MIN_BENCH_ITRS' => 'invalid' })
    assert_equal 2, events.size
    assert_match(/invalid value for Integer/, events.last)
  end

  def test_direct_execution_does_not_write_results
    refute run_harness({ 'RESULT_JSON_PATH' => nil }).any? { |event| event.is_a?(Array) }
  end

  def test_dumps_to_callgrind_default_in_startup_directory
    run_harness({ 'MIN_BENCH_ITRS' => '1' }) do |dir|
      assert_equal 1, Dir.glob(File.join(dir, 'callgrind.out.*.1')).size
    end
  end

  def test_dumps_to_last_out_file_in_valgrind_opts
    opts = '--callgrind-out-file=DIR/ignored.%p --dump-instr=yes --callgrind-out-file=DIR/last.%p'
    run_harness({ 'MIN_BENCH_ITRS' => '1', 'VALGRIND_OPTS' => opts }) do |dir|
      assert_equal 1, Dir.glob(File.join(dir, 'last.*.1')).size
      assert_empty Dir.glob(File.join(dir, 'ignored.*'))
    end
  end

  def test_explains_missing_dump
    events = run_harness({ 'FAKE_DUMP_PREFIX' => 'DIR/elsewhere' })
    assert_match(/dump not found .*pass --callgrind-out-file via VALGRIND_OPTS/, events.last)
  end

  def test_rejects_non_linux
    _, err, status = load_harness(host_os: 'darwin24')
    refute status.success?
    assert_match(/callgrind unsupported/, err)
  end

  def test_rejects_linux_without_callgrind
    %w[ruby memcheck-amd64-].each do |comm|
      _, err, status = load_harness(comm: comm)
      refute status.success?, comm
      assert_match(/must run under `valgrind --tool=callgrind`/, err)
    end
  end
end
