require_relative "../../lib/harness/loader"

Dir.chdir __dir__
use_gemfile

require "addressable/uri"

# Sample URIs for testing
SIMPLE_URI = "http://example.com/path"
COMPLEX_URI = "https://user:pass@example.com:8080/path/to/resource?query=value&foo=bar#fragment"

run_benchmark(100) do
  10000.times do
    # URI parsing - simple and complex
    Addressable::URI.parse(SIMPLE_URI)
    Addressable::URI.parse(COMPLEX_URI)
  end
end
