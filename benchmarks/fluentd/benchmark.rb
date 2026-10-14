# frozen_string_literal: true

require_relative '../../lib/harness/loader'

Dir.chdir(__dir__)
use_gemfile

require 'fluent/engine'
require 'fluent/parser'

# Prepare a fixture
time = Time.new(2023, 7, 27, 9, 00, 00)
errors = [
  "Skipping user-data validation. No user-data found.",
  "Python version change detected. Purging cache",
  "No instance datasource found.",
  "No kernel command line url found.",
  "No local datasource found",
]
ltsv = 1000.times.map { |i| "time:#{time + i}	module:main.py	level:DEBUG	message:#{errors.sample}\n" }.join
ltsv *= 250

# Prepare an LTSV parser
parser = Fluent::Plugin::LabeledTSVParser.new
parser.configure(Fluent::Config::Element.new('parse', '', {}, []))

# Benchmark the `<parse>@type ltsv</parse>` use case
run_benchmark(10) do
  parser.parse(ltsv) {}
end
