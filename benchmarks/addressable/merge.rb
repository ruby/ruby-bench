require_relative "../../lib/harness/loader"

Dir.chdir __dir__
use_gemfile

require "addressable/uri"

SIMPLE_URI = "http://example.com/path"

run_benchmark(100) do
  10000.times do
    # URI merging
    uri = Addressable::URI.parse(SIMPLE_URI)
    uri.merge(scheme: "https", port: 8080)
  end
end
