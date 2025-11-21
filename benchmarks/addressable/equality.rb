require_relative "../../lib/harness/loader"

Dir.chdir __dir__
use_gemfile

require "addressable/uri"

run_benchmark(100) do
  10000.times do
    # URI equality comparison
    uri1 = Addressable::URI.parse("http://example.com")
    uri2 = Addressable::URI.parse("http://example.com:80/")
    uri1 == uri2
  end
end
