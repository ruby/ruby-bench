require_relative '../../harness/loader'
Dir.chdir __dir__
use_gemfile

# The current version is index.erb for the "gem server" command.
# I got it from https://github.com/jnewland/sinatra-rubygems, a
# reimplementation in Sinatra.
TEMPLATE_FILE = "simple_template.erb"

require "json"

#IMPL = "erb"
IMPL = "erubi"

require IMPL

EXPECTED_ERB_TEXT_SIZE = 190579
EXPECTED_ERB_SOURCE_SIZE = 3181

# different newline handling means different final size...
EXPECTED_ERUBI_TEXT_SIZE = 166563
EXPECTED_ERUBI_SOURCE_SIZE = 2666

def generate_source(template_text)
  if IMPL == "erubi"
    src = Erubi::Engine.new(template_text).src
    raise "Wrong generated source size: #{src.size} instead of #{EXPECTED_ERUBI_SOURCE_SIZE}!" unless src.size == EXPECTED_ERUBI_SOURCE_SIZE
  else
    src = ERB.new(template_text).src
    raise "Wrong generated source size: #{src.size} instead of #{EXPECTED_ERB_SOURCE_SIZE}!" unless src.size == EXPECTED_ERB_SOURCE_SIZE
  end
  src
end

def check_result_size(result)
  if IMPL == "erubi"
    raise "Wrong text size: #{result.size} instead of #{EXPECTED_ERUBI_TEXT_SIZE}!" unless result.size == EXPECTED_ERUBI_TEXT_SIZE
  else
    raise "Wrong text size: #{result.size} instead of #{EXPECTED_ERB_TEXT_SIZE}!" unless result.size == EXPECTED_ERB_TEXT_SIZE
  end
end

template = File.read TEMPLATE_FILE
source = generate_source(template)

# Create a method with the generated source
eval <<RUBY
# frozen_string_literal: true
class ErbRenderer
  def initialize(values)
    @values = values
  end
  def run_erb
    #{source}
  end
end
RUBY

# This is taken from actual "gem server" data
VALUES = JSON.load(File.read "gem_specs.json")
Ractor.make_shareable(VALUES)
check_result_size(ErbRenderer.new(VALUES).run_erb)

run_benchmark(50) do
  250.times do
    ErbRenderer.new(VALUES).run_erb
    #.then { |result| check_result_size(result) }
  end
end
