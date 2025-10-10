# frozen_string_literal: true

require_relative "../../harness/loader"

Dir.chdir(__dir__)
use_gemfile

# Rubyboy has a Bench module which is just a loop around `emulator.step`.
# https://github.com/sacckey/rubyboy/blob/e6c7d1d64ed7c6edb0ec6bae25ae3e7ec4cc9319/lib/bench.rb

require 'rubyboy/emulator_headless'

# The rom is included in the gem in a sibling directory to the rubyboy code.
ROM_PATH = File.expand_path("../../roms/tobu.gb", $".detect { |x| x.end_with?("/rubyboy/emulator_headless.rb") }).freeze

# A count of 500 produces results similar to our optcarrot benchmark.
# It's possible there is a number that produces a consistent benchmark without
# needing to re-initialize but not sure how to determine that.
COUNT = 500

Ractor.make_shareable(Rubyboy::ApuChannels::Channel1::WAVE_DUTY)
Ractor.make_shareable(Rubyboy::ApuChannels::Channel2::WAVE_DUTY)

run_benchmark(200) do
  # Results are much more consistent if we re-initialize each time.
  # Reusing the same eumlator increases stddev by 65x.
  emulator = Rubyboy::EmulatorHeadless.new(ROM_PATH)
  COUNT.times do
    emulator.step
  end
end
