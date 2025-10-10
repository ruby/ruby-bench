require_relative 'test_helper'
require 'yaml'

describe 'benchmarks.yml' do
  it 'lists standard Ruby/JIT benchmarks, excluding custom Ractor benchmarks' do
    yjit_bench = File.expand_path('..', __dir__)
    benchmarks_yml = YAML.load_file("#{yjit_bench}/benchmarks.yml")
    benchmarks = Dir.glob("#{yjit_bench}/benchmarks/*").map do |entry|
      File.basename(entry).delete_suffix('.rb') unless File.basename(entry) == "ractor"
    end.compact
    assert_equal benchmarks.sort, benchmarks_yml.keys.sort
  end
end
