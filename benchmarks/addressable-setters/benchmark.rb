require_relative "../../harness/loader"

Dir.chdir __dir__
use_gemfile

require "addressable/uri"

SIMPLE_URI = "http://example.com/path"

run_benchmark(100) do
  100.times do
    # Component modification
    uri = Addressable::URI.parse(SIMPLE_URI)
    uri.scheme = "https"
    uri.host = "newhost.com"
    uri.path = "/newpath"
  end
end
