require_relative "../../lib/harness/loader"

Dir.chdir __dir__
use_gemfile

require "addressable/uri"

run_benchmark(100) do
  10000.times do
    # URI joining
    base = Addressable::URI.parse("http://example.com/a/b/c")
    base.join("../d")
  end
end
