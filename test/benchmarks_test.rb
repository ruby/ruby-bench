require_relative 'test_helper'
require_relative '../lib/benchmark_discovery'
require 'yaml'

describe 'benchmarks.yml' do
  it 'lists all available benchmarks' do
    yjit_bench = File.expand_path('..', __dir__)
    benchmarks_yml = YAML.load_file("#{yjit_bench}/benchmarks.yml")

    # Use BenchmarkDiscovery to find all benchmarks
    benchmarks_dir = File.join(yjit_bench, 'benchmarks')
    benchmarks_ractor_dir = File.join(yjit_bench, 'benchmarks-ractor')

    benchmarks = []
    benchmarks.concat(BenchmarkDiscovery.new(benchmarks_dir).discover.map(&:name))
    benchmarks.concat(BenchmarkDiscovery.new(benchmarks_ractor_dir).discover.map { |e| "ractor/#{e.name}" })

    # Compare discovered benchmarks with those in benchmarks.yml
    # Note: benchmarks.yml may have entries with "ractor/" prefix which we normalize
    yml_keys = benchmarks_yml.keys.sort
    discovered_keys = benchmarks.sort

    assert_equal yml_keys, discovered_keys
  end
end
