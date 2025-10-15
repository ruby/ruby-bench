require_relative 'test_helper'
require 'yaml'

describe 'benchmarks.yml' do
  it 'lists all available benchmarks' do
    yjit_bench = File.expand_path('..', __dir__)
    benchmarks_yml = YAML.load_file("#{yjit_bench}/benchmarks.yml")

    benchmarks = Dir.glob("#{yjit_bench}/benchmarks/*").map do |entry|
      File.basename(entry).delete_suffix('.rb')
    end.compact

    benchmarks += Dir.glob("#{yjit_bench}/benchmarks-ractor/*").map do |entry|
      File.basename(entry).delete_suffix('.rb')
    end.compact

    assert_equal benchmarks.sort, benchmarks_yml.keys.map{ |k| k.gsub('ractor/', '') }.sort
  end
end
