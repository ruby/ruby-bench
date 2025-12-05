# frozen_string_literal: true

require_relative "../../lib/harness/loader"

Dir.chdir(__dir__)
use_gemfile

require "rack"

# Start a server
stack = Rack::Builder.new do
  use Rack::MethodOverride
  use Rack::ConditionalGet
  use Rack::ETag
  use Rack::Deflater
  use Rack::Sendfile
  use Rack::ContentLength
  use Rack::Static
  map "/ok" do
    app = lambda do |env|
      [
        200,
        {
          "content-type" => "text/plain",
          "last-modified" => "Tue, 12 May 2024 13:41:50 +0200"
        },
        [Rack::Request.new(env).path_info]
      ]
    end
    run app
  end
end.to_app

env = Rack::MockRequest::env_for("http://localhost/ok")
env["HTTP_IF_NONE_MATCH"] = "miss-etag"
env["HTTP_IF_MODIFIED_SINCE"] = "Tue, 07 May 2024 13:41:50 +0200"
env.freeze

run_benchmark(100) do
  10_000.times do
    # The app may mutate `env`, so we need to create one every time.
    response = stack.call(env.dup)
    unless response[0] == 200
      raise "HTTP response is #{response.first.inspect} instead of 200. Is the benchmark app properly set up? See README.md."
    end
  end
end
