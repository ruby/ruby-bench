# frozen_string_literal: true

require_relative "../../lib/harness/loader"

Dir.chdir(__dir__)
use_gemfile

# This benchmark RuboCop's performance when auto correcting violations in a file

require "stringio" # TODO: Remove this once https://github.com/rubocop/rubocop/pull/13234 is released
require "rubocop"

# Create a custom runner class to easily pass the content via a stdin option. This is exactly how the Ruby LSP
# integrates with RuboCop
class RuboCopRunner < RuboCop::Runner
  def initialize
    super(
      ::RuboCop::Options.new.parse(
        [
          "--stderr",
          "--force-exclusion",
          "--format",
          "RuboCop::Formatter::BaseFormatter",
          "--raise-cop-error",
          "--autocorrect",
        ]
      ).first,
      ::RuboCop::ConfigStore.new
    )

  end

  def run(path, contents)
    @options[:stdin] = contents
    super([path])
  end
end

file_path = File.expand_path("fixture.rb", __dir__)
contents = File.read(file_path)
runner = RuboCopRunner.new

run_benchmark(200) do
  runner.run(file_path, contents)
end
