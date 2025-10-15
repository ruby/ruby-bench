# frozen_string_literal: true
# This harness runs a single iteration of the benchmark and then returns.
# For simplicity, the benchmark is _not_ timed.
#
# Intended only for checking whether the benchmark can set itself up properly
# and can run to completion.

require_relative '../harness/harness-common'

def run_benchmark(_hint, **)
  yield
  return_results([], [0.001]) # bogus timing
end
