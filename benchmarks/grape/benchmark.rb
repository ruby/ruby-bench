# frozen_string_literal: true

require_relative "../../harness/loader"

Dir.chdir(__dir__)
use_gemfile

require "grape"

# Adapted from Grape's version_throughput benchmark:
# https://github.com/ruby-grape/grape/tree/master/benchmark/version_throughput
class BenchAPI < Grape::API
  prefix :api
  format :json
  version "v1", using: :path

  get "/hello" do
    { hello: "world" }
  end
end

env_template = Rack::MockRequest.env_for("/api/v1/hello", method: Rack::GET).freeze

# Sanity check: 200 OK, body contains expected payload
status, _headers, body = BenchAPI.call(env_template.dup)
raise "sanity check failed: status=#{status}" unless status == 200
collected = +""
body.each { |chunk| collected << chunk }
raise "sanity check failed: body=#{collected.inspect}" unless collected.include?("world")

run_benchmark(100) do
  60_000.times do
    response = BenchAPI.call(env_template.dup)
    unless response[0] == 200
      raise "HTTP response is #{response.first.inspect} instead of 200"
    end
  end
end
