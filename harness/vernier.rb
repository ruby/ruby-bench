# frozen_string_literal: true

# Profile the benchmark (ignoring initialization code) using vernier and display the profile.
# Set NO_VIERWER=1 to disable automatically opening the profile in a browser.
# Usage:
# ./run_once.rb --harness=vernier benchmarks/...
# NO_VIEWER=1 ./run_once.rb --harness=vernier benchmarks/...

require_relative "../lib/harness"
require_relative "../lib/harness/extra"

ensure_global_gem("vernier")
ensure_global_gem_exe("profile-viewer")

def run_benchmark(n, **kwargs, &block)
  require "vernier"

  out = output_file_path(ext: "json")
  Vernier.profile(out: out) do
    run_enough_to_profile(n, **kwargs, &block)
  end

  puts "Vernier profile:\n#{out}"
  gem_exe("profile-viewer", out) unless ENV['NO_VIEWER'] == '1'

  # Dummy results to satisfy ./run_benchmarks.rb
  return_results([0], [1.0])
end
