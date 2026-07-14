require_relative '../../harness/loader'

Dir.chdir __dir__
use_gemfile

require 'liquid_il'
require 'json'

# LiquidIL compiles Liquid templates to standalone Ruby (see extract.rb). We
# render that committed generated Ruby here, so this benchmark exercises the
# machine-generated code a JIT actually compiles: heavy runtime-helper dispatch,
# partial lambdas, string-buffer building, hash lookups, and loops. The exact
# Ruby lives in generated/ and does not drift with the LiquidIL compiler.
manifest = JSON.parse(File.read(File.join(__dir__, 'manifest.json')))
CASES = manifest.map do |m|
  require File.join(__dir__, 'generated', "#{m['spec']}.rb")
  mod = Object.const_get(m['module'])
  assigns = JSON.parse(File.read(File.join(__dir__, 'fixtures', "#{m['spec']}.json")))
  [mod, assigns]
end

# Sanity: every generated module must produce output, or the timing is empty.
CASES.each { |mod, assigns| raise "empty render for #{mod}" if mod.render(assigns).to_s.empty? }

run_benchmark(150) do
  # Each render is quick; render the whole template set several times per
  # iteration to reduce time-measurement noise (mirrors liquid-render).
  100.times do
    CASES.each { |mod, assigns| mod.render(assigns) }
  end
end
