require_relative 'test_helper'
require 'open3'
require 'tmpdir'
require 'json'
require 'rbconfig'

# Exercises harness-ractor's opt-in Ractor-local GC mode (RUBY_BENCH_RACTOR_GC=1)
# against a real target Ruby in a subprocess. The target must provide
# Ractor-local GC counters; use RACTOR_GC_TEST_RUBY to point at such a build.
describe 'Ractor GC harness' do
  ROOT = File.expand_path('..', __dir__)

  # The target is a different Ruby build: never leak this process's bundler
  # setup into the child.
  CLEAN_ENV = {
    'RUBYOPT' => nil,
    'RUBYLIB' => nil,
    'BUNDLE_GEMFILE' => nil,
    'BUNDLER_SETUP' => nil,
  }.freeze

  # Separate-process scope preflight: enabling total-time measurement inside a
  # worker must not change the controller's setting on a Ractor-local build.
  SCOPE_PROBE = <<~'RUBY'
    Warning[:experimental] = false
    GC.measure_total_time = false
    worker = Ractor.new { GC.measure_total_time = true; nil }
    Ractor.select(worker)
    puts(GC.measure_total_time ? "shared" : "local")
  RUBY

  WORKLOAD_BODY = <<~'RUBY'
    GC.measure_total_time = false
    run_benchmark(2, ractor_args: [{ seen: [] }]) do |count, payload|
      raise "unexpected worker count #{count.inspect}" unless [0, 1, 2].include?(count)
      raise "ractor_args not copied per call: #{payload[:seen].inspect}" unless payload[:seen].empty?
      payload[:seen] << count
      20_000.times { Object.new }
      GC.start(full_mark: true, immediate_sweep: true)
      GC.start(full_mark: true, immediate_sweep: true)
    end
    puts "restored=#{GC.measure_total_time == false}"
  RUBY

  # Count 0 completes; positive counts raise inside the workload. The script
  # rescues so it can report whether the harness restored the main Ractor's
  # saved GC measurement setting through its outer ensure, then exits nonzero.
  FAILING_WORKLOAD_BODY = <<~'RUBY'
    GC.measure_total_time = false
    begin
      run_benchmark(2) do |count|
        raise "worker #{count} boom" if count > 0
        10_000.times { Object.new }
      end
    rescue StandardError => e
      puts "failed: #{e.class}"
    end
    puts "restored=#{GC.measure_total_time == false}"
    exit(1)
  RUBY

  # Undefining a required API must fail the run before any warmup work:
  # the workload block backs both warmup and measurement, so it never running
  # proves the prerequisite check precedes warmup.
  UNSUPPORTED_API_BODY = <<~'RUBY'
    class << GC
      undef_method :total_time
    end
    workload_ran = false
    begin
      run_benchmark(2) { |_count| workload_ran = true }
    rescue NotImplementedError => e
      puts "raised: #{e.message}"
    end
    puts "workload_ran=#{workload_ran}"
  RUBY

  before do
    @explicit_target = !ENV['RACTOR_GC_TEST_RUBY'].nil?
    @ruby = ENV['RACTOR_GC_TEST_RUBY'] || RbConfig.ruby

    begin
      out, err, status = Open3.capture3(CLEAN_ENV, @ruby, '--disable-gems', '-e', SCOPE_PROBE)
    rescue SystemCallError => e
      flunk("RACTOR_GC_TEST_RUBY target failed to execute: #{e.message}") if @explicit_target
      skip("test ruby #{@ruby} is not executable")
    end

    unless status.success?
      detail = "target #{@ruby} failed the scope probe (exit #{status.exitstatus}): #{err.strip}"
      flunk("RACTOR_GC_TEST_RUBY #{detail}") if @explicit_target
      skip("test ruby #{detail}")
    end

    unless out.strip == 'local'
      flunk("RACTOR_GC_TEST_RUBY target #{@ruby} does not provide Ractor-local GC") if @explicit_target
      skip("test ruby #{@ruby} has shared GC counters; set RACTOR_GC_TEST_RUBY to a Ractor-local build")
    end
  end

  def run_workload(dir, body, result_path)
    script = File.join(dir, 'workload.rb')
    File.write(script, "Warning[:experimental] = false\nrequire #{File.join(ROOT, 'harness', 'loader').inspect}\n" + body)
    env = CLEAN_ENV.merge(
      'RUBY_BENCH_RACTOR_GC' => '1',
      'RUBY_BENCH_RACTORS' => '0,1,2',
      'WARMUP_ITRS' => '1',
      'MIN_BENCH_ITRS' => '2',
      'MAX_BENCH_ITRS' => '2',
      'MIN_BENCH_TIME' => '0',
      'RESULT_JSON_PATH' => result_path
    )
    Open3.capture3(env, @ruby, "-I#{File.join(ROOT, 'harness-ractor')}", script, chdir: ROOT)
  end

  it 'collects per-worker GC samples for counts 0, 1, and 2' do
    Dir.mktmpdir do |dir|
      result_path = File.join(dir, 'results.json')
      stdout, stderr, status = run_workload(dir, WORKLOAD_BODY, result_path)
      assert status.success?, "workload failed:\n#{stdout}\n#{stderr}"

      # The harness enables main-Ractor measurement for the whole
      # run_benchmark call and restores the saved setting afterwards.
      assert_includes stdout, 'restored=true'

      data = JSON.parse(File.read(result_path))
      assert_equal 'ractor-local-workload', data['gc_scope']
      assert_equal %w[0 1 2], data['bench_by_ractors'].keys.sort
      assert_equal %w[0 1 2], data['gc_by_ractors'].keys.sort

      expected_worker_keys = %w[
        gc_count gc_major_count gc_minor_count gc_marking_time gc_sweeping_time
        gc_total_time_ns worker_index wall_time gc_stat_heap_delta gc_heap_after
      ].sort

      data['gc_by_ractors'].each do |count, group|
        assert_equal 2, data['bench_by_ractors'][count].length, "count #{count} timing samples (warmup excluded)"
        assert_equal 2, group['gc_worker_samples'].length, "count #{count} measured iterations"

        %w[gc_count_bench gc_major_count_bench gc_minor_count_bench gc_total_time_bench].each do |series|
          assert_equal 2, group[series].length, "count #{count} #{series}"
        end
        %w[gc_marking_time_bench gc_sweeping_time_bench].each do |series|
          assert_equal 2, group[series].length, "count #{count} #{series}" if group.key?(series)
        end

        expected_workers = [count.to_i, 1].max
        group['gc_worker_samples'].each_with_index do |workers, i|
          assert_equal expected_workers, workers.length, "count #{count} iteration #{i} worker records"
          assert_equal (0...expected_workers).to_a, workers.map { |w| w['worker_index'] }, 'spawn-index order'

          workers.each do |w|
            assert_equal expected_worker_keys, w.keys.sort
            assert_operator w['gc_count'], :>, 0, 'every worker records GC activity'
            assert_operator w['gc_total_time_ns'], :>, 0
            assert_kind_of Hash, w['gc_heap_after'], 'worker heaps survive worker termination'
            refute_empty w['gc_heap_after']
          end

          # Per-iteration aggregates are sums of that iteration's worker
          # records, not a main-Ractor snapshot.
          assert_equal workers.sum { |w| w['gc_count'] }, group['gc_count_bench'][i]
          assert_equal workers.sum { |w| w['gc_major_count'] }, group['gc_major_count_bench'][i]
          assert_equal workers.sum { |w| w['gc_minor_count'] }, group['gc_minor_count_bench'][i]
          ns_sum = workers.sum { |w| w['gc_total_time_ns'] }
          assert_in_delta ns_sum / 1_000_000.0, group['gc_total_time_bench'][i], 1e-9
        end

        if count == '0'
          refute group.key?('gc_controller_samples'), 'count 0 must not double-count the main Ractor'
        else
          assert_equal 2, group['gc_controller_samples'].length
          group['gc_controller_samples'].each do |controller|
            refute controller.key?('worker_index')
            refute controller.key?('wall_time')
          end
        end
      end
    end
  end

  it 'propagates a worker failure without writing partial or dummy results' do
    Dir.mktmpdir do |dir|
      result_path = File.join(dir, 'results.json')
      stdout, stderr, status = run_workload(dir, FAILING_WORKLOAD_BODY, result_path)

      refute status.success?, "expected worker failure to fail the run:\n#{stdout}\n#{stderr}"
      assert_includes stdout, 'failed: Ractor::RemoteError'
      assert_includes stdout, 'restored=true', 'outer ensure must restore the main-Ractor setting on worker failure'
      refute File.exist?(result_path), 'no results file may be written for a failed benchmark'
    end
  end

  it 'fails before warmup when the target lacks the required GC APIs' do
    Dir.mktmpdir do |dir|
      result_path = File.join(dir, 'results.json')
      stdout, stderr, status = run_workload(dir, UNSUPPORTED_API_BODY, result_path)

      assert status.success?, "probe script itself failed:\n#{stdout}\n#{stderr}"
      assert_includes stdout, 'raised: Ractor GC metrics require GC.total_time and GC.measure_total_time='
      assert_includes stdout, 'workload_ran=false'
      refute File.exist?(result_path), 'no results file may be written for an unsupported target'
    end
  end
end
