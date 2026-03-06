# Copyright 2009 the V8 project authors. All rights reserved.
# Copyright (C) 2015 Apple Inc. All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
#
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above
#       copyright notice, this list of conditions and the following
#       disclaimer in the documentation and/or other materials provided
#       with the distribution.
#     * Neither the name of Google Inc. nor the names of its
#       contributors may be used to endorse or promote products derived
#       from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# Ported to Ruby from the V8/WebKit JavaScript benchmark suite.
# https://browserbench.org/JetStream2.1/Octane/splay.js

require_relative '../harness/loader'

class SplayTree
  class Node
    attr_accessor :key, :value, :left, :right

    def initialize(key, value)
      @key = key
      @value = value
      @left = nil
      @right = nil
    end
  end

  def initialize
    @root = nil
  end

  def empty?
    @root.nil?
  end

  def insert(key, value)
    if empty?
      @root = Node.new(key, value)
      return
    end
    splay!(key)
    return if @root.key == key
    node = Node.new(key, value)
    if key > @root.key
      node.left = @root
      node.right = @root.right
      @root.right = nil
    else
      node.right = @root
      node.left = @root.left
      @root.left = nil
    end
    @root = node
  end

  def remove(key)
    raise "Key not found: #{key}" if empty?
    splay!(key)
    raise "Key not found: #{key}" if @root.key != key
    removed = @root
    if @root.left.nil?
      @root = @root.right
    else
      right = @root.right
      @root = @root.left
      splay!(key)
      @root.right = right
    end
    removed
  end

  def find(key)
    return nil if empty?
    splay!(key)
    @root.key == key ? @root : nil
  end

  def find_max(start_node = nil)
    return nil if empty?
    current = start_node || @root
    current = current.right while current.right
    current
  end

  def find_greatest_less_than(key)
    return nil if empty?
    splay!(key)
    if @root.key < key
      @root
    elsif @root.left
      find_max(@root.left)
    end
  end

  private

  def splay!(key)
    return if empty?
    dummy = Node.new(nil, nil)
    left = dummy
    right = dummy
    current = @root
    loop do
      if key < current.key
        break unless current.left
        if key < current.left.key
          tmp = current.left
          current.left = tmp.right
          tmp.right = current
          current = tmp
          break unless current.left
        end
        right.left = current
        right = current
        current = current.left
      elsif key > current.key
        break unless current.right
        if key > current.right.key
          tmp = current.right
          current.right = tmp.left
          tmp.left = current
          current = tmp
          break unless current.right
        end
        left.right = current
        left = current
        current = current.right
      else
        break
      end
    end
    left.right = current.left
    right.left = current.right
    current.left = dummy.right
    current.right = dummy.left
    @root = current
  end
end

TREE_SIZE = 8000
MODIFICATIONS = 80
PAYLOAD_DEPTH = 5

class PayloadNode
  attr_accessor :left, :right
  def initialize(left, right)
    @left = left
    @right = right
  end
end

def generate_payload(depth, tag)
  if depth == 0
    { array: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
      string: "String for key #{tag} in leaf node" }
  else
    PayloadNode.new(
      generate_payload(depth - 1, tag),
      generate_payload(depth - 1, tag)
    )
  end
end

def insert_new_node(tree, rng)
  loop do
    key = rng.rand
    next if tree.find(key)
    tree.insert(key, generate_payload(PAYLOAD_DEPTH, key.to_s))
    return key
  end
end

def splay_setup(rng)
  tree = SplayTree.new
  TREE_SIZE.times { insert_new_node(tree, rng) }
  tree
end

def splay_run(tree, rng)
  MODIFICATIONS.times do
    key = insert_new_node(tree, rng)
    greatest = tree.find_greatest_less_than(key)
    if greatest
      tree.remove(greatest.key)
    else
      tree.remove(key)
    end
  end
end

rng = Random.new(42)
tree = splay_setup(rng)

run_benchmark(200) do
  50.times { splay_run(tree, rng) }
end
