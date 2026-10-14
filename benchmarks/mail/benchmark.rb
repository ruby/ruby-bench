require_relative "../../lib/harness/loader"

Dir.chdir __dir__
use_gemfile
require "mail"

raw_email = File.binread("raw_email2.eml")

run_benchmark(100) do
  50.times do
    Mail.new(raw_email).to_s
  end
end
