require_relative 'test_helper'
require_relative '../lib/gc_stats'
require 'open3'
require 'tmpdir'
require 'json'
require 'rbconfig'

describe 'Ractor GC harness' do
  ROOT = File.expand_path('..', __dir__)

  CLEAN_ENV = {
    'RUBYOPT' => nil,
    'RUBYLIB' => nil,
    'BUNDLE_GEMFILE' => nil,
    'BUNDLER_SETUP' => nil,
  }.freeze

  VERSION_PROBE = <<~'RUBY'
    puts RUBY_VERSION
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

  COMPACT_WORKLOAD_BODY = <<~'RUBY'
    run_benchmark(2) { |_count| GC.compact }
  RUBY

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

  FAILING_COUNT_ZERO_BODY = <<~'RUBY'
    GC.measure_total_time = false
    $count_zero_calls = 0
    begin
      run_benchmark(2) do |count|
        if count.zero?
          $count_zero_calls += 1
          raise "controller boom" if $count_zero_calls > 1
        end
        10_000.times { Object.new }
      end
    rescue StandardError => e
      puts "failed: #{e.class}"
    end
    puts "restored=#{GC.measure_total_time == false}"
    exit(1)
  RUBY

  UNSUPPORTED_VERSION_BODY = <<~'RUBY'
    def GCStats.ractor_local_gc_supported?(*) = false
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
      out, err, status = Open3.capture3(CLEAN_ENV, @ruby, '--disable-gems', '-e', VERSION_PROBE)
    rescue SystemCallError => e
      flunk("RACTOR_GC_TEST_RUBY target failed to execute: #{e.message}") if @explicit_target
      skip("test ruby #{@ruby} is not executable")
    end

    unless status.success?
      detail = "target #{@ruby} failed the version probe (exit #{status.exitstatus}): #{err.strip}"
      flunk("RACTOR_GC_TEST_RUBY #{detail}") if @explicit_target
      skip("test ruby #{detail}")
    end

    unless GCStats.ractor_local_gc_supported?(out.strip)
      flunk("RACTOR_GC_TEST_RUBY target #{@ruby} is Ruby #{out.strip}; Ractor GC metrics require Ruby 4.1 or newer") if @explicit_target
      skip("test ruby #{@ruby} is Ruby #{out.strip} (< 4.1); set RACTOR_GC_TEST_RUBY to a Ruby 4.1 or newer build")
    end
  end

  def run_workload(body)
    Dir.mktmpdir do |dir|
      result_path = File.join(dir, 'results.json')
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
      stdout, stderr, status = Open3.capture3(env, @ruby, "-I#{File.join(ROOT, 'harness-ractor')}", script, chdir: ROOT)
      yield stdout, stderr, status, result_path
    end
  end

  it 'collects per-worker GC samples for counts 0, 1, and 2' do
    run_workload(WORKLOAD_BODY) do |stdout, stderr, status, result_path|
      assert status.success?, "workload failed:\n#{stdout}\n#{stderr}"

      assert_includes stdout, 'restored=true'

      data = JSON.parse(File.read(result_path))
      assert_equal 'ractor-local-workload', data['gc_scope']
      assert_equal 'ractor-local', data['gc_stat_scope']
      assert_equal 'ractor-local', data['gc_measure_total_time_scope']
      assert_kind_of Hash, data['gc_config']
      assert_equal %w[0 1 2], data['bench_by_ractors'].keys.sort
      assert_equal %w[0 1 2], data['gc_by_ractors'].keys.sort

      controller_series_present = data['gc_by_ractors'].values.any? do |group|
        group.key?('gc_global_count_bench') || group.key?('gc_controller_compact_count_bench')
      end
      if controller_series_present
        assert_includes stdout, '(* process/controller-observed; may overlap the other GC counts and is not additive.)',
          'a starred stdout column must always come with the exact legend line'
      end

      expected_worker_keys = %w[
        gc_count gc_major_count gc_minor_count gc_marking_time gc_sweeping_time
        gc_total_time_ns worker_index wall_time gc_stat_heap_delta gc_heap_after
      ].sort

      data['gc_by_ractors'].each do |count, group|
        assert_equal 2, data['bench_by_ractors'][count].length, "count #{count} timing samples (warmup excluded)"
        assert_equal 2, group['gc_worker_samples'].length, "count #{count} measured iterations"

        %w[
          gc_count_bench gc_major_count_bench gc_minor_count_bench
          gc_marking_time_bench gc_sweeping_time_bench gc_total_time_bench
        ].each do |series|
          assert_equal 2, group[series].length, "count #{count} #{series}"
        end
        %w[gc_global_count_bench gc_controller_compact_count_bench].each do |series|
          next unless group.key?(series)
          assert_equal 2, group[series].length, "count #{count} #{series}"
          group[series].each do |delta|
            assert_kind_of Integer, delta
            assert_operator delta, :>=, 0
          end
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
          controller_keys = %w[gc_global_count_bench gc_controller_compact_count_bench global_gc_count compact_count]
          workers.each do |w|
            controller_keys.each do |key|
              refute w.key?(key), "worker sample must not carry controller-observed #{key}"
            end
          end

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

  it 'excludes collections in another Ractor from a workload sample' do
    body = <<~'RUBY'
      Warning[:experimental] = false
      GC.disable
      worker = Ractor.new do
        GC.disable
        Ractor.receive
        before = GC.stat(:count, scope: :ractor)
        10.times { GC.start(full_mark: false, immediate_sweep: true, global: false) }
        Ractor.main.send(GC.stat(:count, scope: :ractor) - before)
        Ractor.receive
      end

      foreign_count = nil
      sample = GCStats.measure do
        worker.send(:start)
        foreign_count = Ractor.receive
      end
      puts [foreign_count, sample['gc_count'], sample['gc_major_count'], sample['gc_minor_count'], sample['gc_total_time_ns']].inspect
      worker.send(:stop)
      Ractor.select(worker)
    RUBY
    stdout, stderr, status = Open3.capture3(
      CLEAN_ENV, @ruby, '--disable-gems', '-r', File.join(ROOT, 'lib', 'gc_stats'), '-e', body
    )

    assert status.success?, "scope probe failed:\n#{stdout}\n#{stderr}"
    assert_equal [10, 0, 0, 0, 0], JSON.parse(stdout)
  end

  it 'records controller-observed compaction deltas for a GC.compact workload' do
    run_workload(COMPACT_WORKLOAD_BODY) do |stdout, stderr, status, result_path|
      assert status.success?, "workload failed:\n#{stdout}\n#{stderr}"

      data = JSON.parse(File.read(result_path))
      unless data.dig('gc_by_ractors', '0').key?('gc_controller_compact_count_bench')
        skip("target #{@ruby} does not expose GC.stat(:compact_count)")
      end

      data['gc_by_ractors'].each do |count, group|
        deltas = group['gc_controller_compact_count_bench']
        assert_equal 2, deltas.length, "count #{count} compaction deltas"
        if count == '0'
          assert_equal [1, 1], deltas, 'count 0 compacts exactly once per iteration in the main Ractor'
        else
          deltas.each do |delta|
            assert_operator delta, :>=, 1, "count #{count} must observe at least one compacting cycle"
            assert_operator delta, :<=, count.to_i, "count #{count} must not multiply-count compacting cycles"
          end
        end
      end
    end
  end

  it 'propagates a worker failure without writing partial or dummy results' do
    run_workload(FAILING_WORKLOAD_BODY) do |stdout, stderr, status, result_path|
      refute status.success?, "expected worker failure to fail the run:\n#{stdout}\n#{stderr}"
      assert_includes stdout, 'failed: Ractor::RemoteError'
      assert_includes stdout, 'restored=true', 'outer ensure must restore the main-Ractor setting on worker failure'
      refute File.exist?(result_path), 'no results file may be written for a failed benchmark'
    end
  end

  it 'restores the measurement setting when the count-0 workload fails' do
    run_workload(FAILING_COUNT_ZERO_BODY) do |stdout, stderr, status, result_path|
      refute status.success?, "expected count-0 failure to fail the run:\n#{stdout}\n#{stderr}"
      assert_includes stdout, 'failed: RuntimeError'
      assert_includes stdout, 'restored=true', 'both ensures must restore the main-Ractor setting on count-0 failure'
      refute File.exist?(result_path), 'no results file may be written for a failed benchmark'
    end
  end

  it 'fails before warmup when the target Ruby is older than 4.1' do
    run_workload(UNSUPPORTED_VERSION_BODY) do |stdout, stderr, status, result_path|
      assert status.success?, "probe script itself failed:\n#{stdout}\n#{stderr}"
      assert_includes stdout, 'raised: Ractor GC metrics require Ruby 4.1 or newer'
      assert_includes stdout, 'workload_ran=false'
      refute File.exist?(result_path), 'no results file may be written for an unsupported target'
    end
  end

  it 'fails before warmup when the target lacks the required GC APIs' do
    run_workload(UNSUPPORTED_API_BODY) do |stdout, stderr, status, result_path|
      assert status.success?, "probe script itself failed:\n#{stdout}\n#{stderr}"
      assert_includes stdout, 'raised: Ractor GC metrics require GC.total_time and GC.measure_total_time='
      assert_includes stdout, 'workload_ran=false'
      refute File.exist?(result_path), 'no results file may be written for an unsupported target'
    end
  end
end
