# The Computer Language Benchmarks Game
# https://salsa.debian.org/benchmarksgame-team/benchmarksgame/
#
# contributed by Jesse Millikan
# Modified by Wesley Moxam
# *reset*

def item_check(left, right)
  return 1 if left.nil?
  1 + item_check(*left) + item_check(*right)
end

def bottom_up_tree(depth)
  return [nil, nil] unless depth > 0
  depth -= 1
  [bottom_up_tree(depth), bottom_up_tree(depth)]
end

MAX_DEPTH = 14
MIN_DEPTH = 4

MAX_DEPTH = MIN_DEPTH + 2 if MIN_DEPTH + 2 > MAX_DEPTH
STRETCH_DEPTH = MAX_DEPTH + 1

require_relative '../../harness/loader'

run_benchmark(60) do
  max_depth = MAX_DEPTH
  min_depth = MIN_DEPTH
  stretch_depth = STRETCH_DEPTH
  stretch_tree = bottom_up_tree(stretch_depth)
  stretch_tree = nil

  long_lived_tree = bottom_up_tree(max_depth)

  min_depth.step(max_depth, 2) do |depth|
    iterations = 2**(max_depth - depth + min_depth)

    check = 0

    for i in 1..iterations
      temp_tree = bottom_up_tree(depth)
      check += item_check(*temp_tree)
    end
  end
end
