require_relative "../../lib/harness/loader"

Dir.chdir(__dir__)
use_gemfile
require "json"
puts "json v#{JSON::VERSION}"

ELEMENTS = 300_000
list = ELEMENTS.times.map do |i|
  {
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
    "string #{i}" => "value #{i}",
  }.to_json
end
make_shareable(list)

# Work is divided between ractors
run_benchmark(5, ractor_args: [list]) do |num_rs, list|
  # num_rs: 1,list: 100_000
  # num_rs: 2 list: 50_000
  # num_rs: 4 list: 25_000
  if num_rs.zero?
    num = list.size
  else
    num = list.size / num_rs
  end
  list.each_with_index do |json, idx|
    break if idx >= num
    JSON.parse(json)
  end
end
