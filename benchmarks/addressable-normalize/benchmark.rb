require_relative "../../harness/loader"

Dir.chdir __dir__
use_gemfile

require "addressable/uri"

run_benchmark(100) do
  100.times do
    # URI normalization
    uri = Addressable::URI.parse("HTTP://EXAMPLE.COM:80/path")
    uri.normalize
  end
end
