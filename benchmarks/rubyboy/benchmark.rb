# frozen_string_literal: true

require_relative "../../lib/harness/loader"

Dir.chdir(__dir__)
use_gemfile

# Rubyboy has a Bench module which is just a loop around `emulator.step`.
# https://github.com/sacckey/rubyboy/blob/e6c7d1d64ed7c6edb0ec6bae25ae3e7ec4cc9319/lib/bench.rb

require 'rubyboy/emulator_headless'

# A count of 500 produces results similar to our optcarrot benchmark.
# It's possible there is a number that produces a consistent benchmark without
# needing to re-initialize but not sure how to determine that.
COUNT = 500

run_benchmark(200) do
  # Results are much more consistent if we re-initialize each time.
  # Reusing the same eumlator increases stddev by 65x.
  emulator = Rubyboy::EmulatorHeadless.new(Rubyboy::Rom::DEFAULT_PATH)
  COUNT.times do
    emulator.step
  end
end
