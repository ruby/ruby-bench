require_relative "../../lib/harness/loader"

Dir.chdir __dir__
use_gemfile

require "graphql"
require "graphql/c_parser"

file = File.read "negotiate.gql"

run_benchmark(10) do
  100.times do |i|
    GraphQL.parse file
  end
end
