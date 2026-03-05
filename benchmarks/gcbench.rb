# Ellis-Kovac-Boehm GCBench
#
# Adapted from the benchmark by John Ellis and Pete Kovac (Post Communications),
# modified by Hans Boehm (Silicon Graphics), translated to Ruby by Noel Padavan
# and Chris Seaton. Adapted for yjit-bench by Matt Valentine-House.
#
# Builds balanced binary trees of various depths to generate objects with a range
# of lifetimes. Two long-lived structures (a tree and a float array) are kept
# alive throughout to model applications that maintain persistent heap data.
#
# Tree construction uses both top-down (populate — creates old-to-young pointers,
# exercises write barriers) and bottom-up (make_tree — young-to-young only).

require_relative '../harness/loader'

class GCBench
  class Node
    attr_accessor :left, :right, :i, :j

    def initialize(left = nil, right = nil)
      @left = left
      @right = right
      @i = 0
      @j = 0
    end
  end

  STRETCH_TREE_DEPTH   = 18
  LONG_LIVED_TREE_DEPTH = 16
  ARRAY_SIZE            = 500_000
  MIN_TREE_DEPTH        = 4
  MAX_TREE_DEPTH        = 16

  def self.tree_size(depth)
    (1 << (depth + 1)) - 1
  end

  def self.num_iters(depth)
    2 * tree_size(STRETCH_TREE_DEPTH) / tree_size(depth)
  end

  # Top-down: assigns children to an existing (older) node — old-to-young pointers.
  def self.populate(depth, node)
    if depth > 0
      depth -= 1
      node.left = Node.new
      node.right = Node.new
      populate(depth, node.left)
      populate(depth, node.right)
    end
  end

  # Bottom-up: children allocated before parent — young-to-young pointers only.
  def self.make_tree(depth)
    if depth <= 0
      Node.new
    else
      Node.new(make_tree(depth - 1), make_tree(depth - 1))
    end
  end

  def self.time_construction(depth)
    n = num_iters(depth)

    n.times do
      node = Node.new
      populate(depth, node)
    end

    n.times do
      make_tree(depth)
    end
  end
end

# Stretch the heap before measurement
GCBench.make_tree(GCBench::STRETCH_TREE_DEPTH)

# Long-lived objects that persist across all iterations
long_lived_tree = GCBench::Node.new
GCBench.populate(GCBench::LONG_LIVED_TREE_DEPTH, long_lived_tree)

long_lived_array = Array.new(GCBench::ARRAY_SIZE)
(GCBench::ARRAY_SIZE / 2).times { |i| long_lived_array[i + 1] = 1.0 / (i + 1) }

run_benchmark(10) do
  GCBench::MIN_TREE_DEPTH.step(GCBench::MAX_TREE_DEPTH, 2) do |depth|
    GCBench.time_construction(depth)
  end
end
