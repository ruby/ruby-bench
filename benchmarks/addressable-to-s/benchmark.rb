require_relative "../../harness/loader"

Dir.chdir __dir__
use_gemfile

require "addressable/uri"

COMPLEX_URI = "https://user:pass@example.com:8080/path/to/resource?query=value&foo=bar#fragment"

run_benchmark(100) do
  100.times do
    # URI to string conversion
    uri = Addressable::URI.parse(COMPLEX_URI)
    uri.to_s
  end
end
