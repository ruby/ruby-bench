require_relative 'test_helper'
require 'open3'
require 'tmpdir'
require 'rbconfig'

describe 'GC harness' do
  # GC.stat reports marking and sweeping time in whole milliseconds, so the
  # per-iteration deltas are Integers. Stub them to 1, 0, 0 and 3, 2, 2.
  WORKLOAD = <<~'RUBY'
    marks = [1, 0, 0]
    sweeps = [3, 2, 2]
    original = GCStats.method(:delta)
    GCStats.define_singleton_method(:delta) do |before, after|
      original.call(before, after).merge("gc_marking_time" => marks.shift || 0, "gc_sweeping_time" => sweeps.shift || 0)
    end
    run_benchmark(1) {}
  RUBY

  it 'prints average marking and sweeping times without truncating them' do
    skip 'GC.stat has no marking_time on this Ruby' unless GC.stat.key?(:marking_time) && GC.stat.key?(:sweeping_time)

    Dir.mktmpdir do |dir|
      env = { 'WARMUP_ITRS' => '0', 'MIN_BENCH_ITRS' => '3', 'MIN_BENCH_TIME' => '0', 'RESULT_JSON_PATH' => File.join(dir, 'out.json') }
      harness = File.expand_path('../harness/gc', __dir__)
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, '-r', harness, '-e', WORKLOAD)

      assert status.success?, stderr
      assert_includes stdout, 'Average marking time: 0.3ms'
      assert_includes stdout, 'Average sweeping time: 2.3ms'
    end
  end
end
