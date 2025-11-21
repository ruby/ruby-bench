require_relative "../../lib/harness/loader"

Dir.chdir __dir__
use_gemfile

require "addressable/uri"

COMPLEX_URI = "https://user:pass@example.com:8080/path/to/resource?query=value&foo=bar#fragment"

run_benchmark(100) do
  10000.times do
    # Component access
    uri = Addressable::URI.parse(COMPLEX_URI)
    uri.scheme
    uri.host
    uri.port
    uri.path
    uri.query
    uri.fragment
  end
end
