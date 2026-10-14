require_relative "../../lib/harness/loader"

Dir.chdir __dir__
use_gemfile

require "tinygql"

file = File.read "negotiate.gql"

run_benchmark(10) do
  100.times do |i|
    TinyGQL.parse file
  end
end
