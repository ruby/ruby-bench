# frozen_string_literal: true

module RactorCounts
  DEFAULT = [0, 1, 2, 4, 6, 8].freeze
  ENV_VAR = "RUBY_BENCH_RACTORS"

  module_function

  def from_env(env = ENV)
    counts = env.fetch(ENV_VAR, "").split(",").map(&:to_i).sort.uniq
    counts.empty? ? DEFAULT : counts.freeze
  end
end
