require_relative "../../harness/loader"

Dir.chdir __dir__
use_gemfile

require "addressable/uri"

run_benchmark(100) do
  100.times do
    # URI construction from hash
    Addressable::URI.new(
      scheme: "https",
      host: "example.com",
      port: 443,
      path: "/path",
      query: "foo=bar"
    )
  end
end
