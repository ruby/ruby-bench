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
      File.write(File.join(gem_lib, 'valgrind.rb'), <<~RUBY)
        module Valgrind
          def self.callgrind_stop_instrumentation; $events << 'stop'; end
          def self.callgrind_start_instrumentation; $events << 'start'; end
          def self.callgrind_zero_stats; $events << 'zero'; end
          def self.callgrind_dump_stats(name); $events << "dump:" + name; end
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
        def return_results(warmup, bench)
          $events << ['results', warmup.size, bench.size]
        end
        calls = 0
        begin
          run_benchmark(3, ignored_keyword: true) do
            calls += 1
            $events << 'work'
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
        'RESULT_JSON_PATH' => File.join(dir, 'results.json')
      }.merge(env)
      out, err, status = Open3.capture3(clean_env, RbConfig.ruby, '-I', dir, '-e', script, chdir: ROOT)
      assert status.success?, "#{out}\n#{err}"
      JSON.parse(out.lines.last)
    end
  end

  def test_profiles_hint_iterations_after_warmup
    assert_equal ['stop', 'stop', 'work', 'work', 'start', 'zero',
                  'work', 'work', 'work', 'stop', 'dump:-e', ['results', 2, 3]], run_harness
  end

  def test_iteration_overrides_and_zero_warmup
    assert_equal ['stop', 'stop', 'start', 'zero', 'work', 'stop', 'dump:-e', ['results', 0, 1]],
                 run_harness({ 'WARMUP_ITRS' => '0', 'MIN_BENCH_ITRS' => '1' })
  end

  def test_failure_stops_and_dumps_without_results
    assert_equal ['stop', 'stop', 'work', 'work', 'start', 'zero', 'work',
                  'stop', 'dump:-e', 'workload failed'], run_harness({}, fail_at: 3)
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
