require_relative 'test_helper'
require 'open3'
require 'tmpdir'
require 'json'
require 'rbconfig'
require 'fileutils'

class CallgrindHarnessTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def run_harness(env = {}, fail_at: nil, missing: false, install_success: true)
    Dir.mktmpdir do |dir|
      # Fake a bundle-installed native gem that is not on the initial load path.
      gem_lib = File.join(dir, 'bundle', 'lib')
      FileUtils.mkdir_p(gem_lib)
      File.write(File.join(dir, 'bundler.rb'), <<~RUBY)
        module Bundler
          class BundlerError < StandardError; end
          class GemNotFound < BundlerError; end
          def self.reset!; end
          def self.with_unbundled_env
            original = ENV['BUNDLE_GEMFILE']
            yield
          ensure
            original ? ENV['BUNDLE_GEMFILE'] = original : ENV.delete('BUNDLE_GEMFILE')
          end
          class Definition
            def self.build(gemfile, lockfile, unlock)
              raise 'wrong Gemfile' unless gemfile == #{File.join(ROOT, 'Gemfile').inspect}
              raise 'wrong lockfile' unless lockfile == gemfile + '.lock'
              raise 'unexpected unlock' unless unlock.nil?
              new
            end
            def specs_for(groups)
              raise 'wrong groups' unless groups == [:callgrind]
              raise GemNotFound, 'valgrind is not installed' if #{missing.inspect} && !$installed
              [Struct.new(:full_require_paths).new([#{gem_lib.inspect}])]
            end
          end
        end
      RUBY
      File.write(File.join(gem_lib, 'valgrind.rb'), <<~RUBY)
        module Valgrind
          def self.callgrind_stop_instrumentation; $events << 'stop'; end
          def self.callgrind_start_instrumentation; $events << 'start'; end
          def self.callgrind_zero_stats; $events << 'zero'; end
          def self.callgrind_dump_stats(name); $events << "dump:" + name; end
        end
      RUBY
      script = <<~RUBY
        require 'json'
        $events = []
        def system(env, *command)
          raise 'wrong install group' unless env == { 'BUNDLE_WITH' => 'callgrind' }
          raise 'wrong install command' unless command == [RbConfig.ruby, '-S', 'bundle', 'install']
          raise 'wrong install Gemfile' unless ENV['BUNDLE_GEMFILE'] == #{File.join(ROOT, 'Gemfile').inspect}
          $events << 'install'
          $installed = #{install_success.inspect}
        end
        begin
          require #{File.join(ROOT, 'harness/callgrind').inspect}
        rescue LoadError => e
          puts JSON.generate($events + [e.message])
          exit
        end
        raise 'Gemfile environment leaked' if ENV['BUNDLE_GEMFILE']
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

  def test_missing_bundle_is_installed_automatically
    assert_equal ['install'] + run_harness, run_harness({}, missing: true)
  end

  def test_install_failure_reports_install_command_without_running_workload
    events = run_harness({}, missing: true, install_success: false)
    assert_equal 2, events.size
    assert_equal 'install', events.first
    assert_includes events.last, 'bundle install failed'
    assert_includes events.last, 'BUNDLE_WITH=callgrind bundle install'
  end

  def test_direct_execution_does_not_write_results
    refute run_harness({ 'RESULT_JSON_PATH' => nil }).any? { |event| event.is_a?(Array) }
  end
end
