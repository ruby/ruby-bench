require_relative 'test_helper'
require 'json'
require 'open3'
require 'tmpdir'

describe 'Ractor harness' do
  it 'warms up at the measured Ractor count' do
    skip 'target Ruby has no Ractor' unless defined?(Ractor)
    root = File.expand_path('..', __dir__)
    Dir.mktmpdir do |dir|
      result_path = File.join(dir, 'results.json')
      calls_path = File.join(dir, 'calls.txt')
      script = File.join(dir, 'workload.rb')
      File.write(script, <<~RUBY)
        require #{File.join(root, 'harness', 'loader').inspect}
        run_benchmark(1) do |count|
          File.open(#{calls_path.inspect}, 'a') { |f| f.puts(count) }
        end
      RUBY
      env = {
        'RUBYOPT' => nil,
        'RUBYLIB' => nil,
        'BUNDLE_GEMFILE' => nil,
        'RUBY_BENCH_RACTORS' => '2',
        'WARMUP_ITRS' => '2',
        'MIN_BENCH_ITRS' => '1',
        'RESULT_JSON_PATH' => result_path
      }

      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-I#{File.join(root, 'harness-ractor')}", script)

      assert status.success?, "workload failed:\n#{stdout}\n#{stderr}"
      assert_equal ['2'], JSON.parse(File.read(result_path))['bench_by_ractors'].keys
      assert_equal ['2'] * 6, File.readlines(calls_path, chomp: true), '(2 warmup + 1 measured) iterations x 2 Ractors'
    end
  end
end
