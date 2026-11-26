# frozen_string_literal: true

# Heap balloon/release benchmark, intended for the Ractor harness with --ractor-gc.
#
# Each Ractor repeatedly inflates a large retained object graph in its own
# object space, ages it into the old generation, and drops it:
#
#   grow     allocate and retain BALLOON_CHUNKS chunks, filling pages with
#            live balloon objects across most of the size pools
#   settle   allocate throwaway garbage while the balloon is still live, so
#            minor GCs age the whole balloon into the old generation
#   release  drop the balloon in one go, turning it into old-generation
#            garbage that only a major GC can reclaim
#   collect  collect at the low-water mark, while the live set is small, so
#            the pages the balloon filled are emptied and become surplus
#   idle     allocate a little more garbage on the shrunken heap
#
# Work per Ractor is fixed and independent of the Ractor count, so GC totals
# scale with the number of workers and per-Ractor degradation is the signal.

require_relative '../harness/loader'

class GCBalloon
  Record = Struct.new(:id, :head, :tail, :link)

  # Embedded arrays of these widths land in distinct size pools, so the
  # balloon is spread over most of the heaps rather than just one.
  ARRAY_WIDTHS = [3, 8, 18, 30, 62, 126].freeze

  # Duping a frozen literal keeps the copy embedded, so these land in distinct
  # pools too. Only lengths up to about 136 bytes still embed.
  SEED_STRINGS = [
    ("s" * 8).freeze,
    ("m" * 40).freeze,
    ("l" * 104).freeze,
    ("x" * 136).freeze,
  ].freeze

  # Past the embed limit a string is a small slot plus a malloc'd buffer, so
  # this is the part of the balloon that page release cannot hand back.
  BLOB_BYTES = 2048

  # Chunks retained at the peak of a cycle: about 27MiB of heap pages plus
  # 12MiB of malloc'd blobs per Ractor.
  BALLOON_CHUNKS = 6_000
  CYCLES = 4

  # Throwaway objects per retained chunk. The settle count has to be high
  # enough to drive the several minor GCs it takes to age the balloon.
  SETTLE_PER_CHUNK = 84
  IDLE_PER_CHUNK   = 25

  CHURN_WIDTH = 8  # width of each throwaway churn array
  CHURN_RING  = 64 # churn arrays kept reachable at a time

  COLLECT_AT_LOW_WATER = ENV.fetch("RUBY_BENCH_BALLOON_COLLECT", "1") == "1"

  LOCAL_MAJOR_ONLY = true

  # One retained chunk. The strings and the blob are allocated before the
  # arrays that reference them, so marking has a graph to walk rather than a
  # block of immediates.
  def self.build_chunk(i)
    strings = SEED_STRINGS.map(&:dup)
    blob = "\0" * BLOB_BYTES
    record = Record.new(i, strings.first, blob, nil)
    rows = ARRAY_WIDTHS.map { |width| Array.new(width) { |k| strings[k % strings.size] } }
    record.link = rows.first
    index = { id: i, record: record, rows: rows, blob: blob }
    [record, index, blob, *rows, *strings]
  end

  def self.grow(chunks)
    balloon = Array.new(chunks)
    i = 0
    while i < chunks
      balloon[i] = build_chunk(i)
      i += 1
    end
    balloon
  end

  # Allocate short-lived garbage without growing the live set: only the last
  # CHURN_RING arrays stay reachable. Storing into a ring that is itself old
  # by now also keeps the write barrier in play.
  def self.churn(objects)
    ring = Array.new(CHURN_RING)
    i = 0
    while i < objects
      ring[i % CHURN_RING] = Array.new(CHURN_WIDTH, i)
      i += 1
    end
    ring
  end

  def self.collect_at_low_water
    LOCAL_MAJOR_ONLY ? GC.start(global: false) : GC.start
  end

  def self.run
    cycle = 0
    while cycle < CYCLES
      balloon = grow(BALLOON_CHUNKS)
      churn(BALLOON_CHUNKS * SETTLE_PER_CHUNK)
      balloon = nil
      collect_at_low_water if COLLECT_AT_LOW_WATER
      churn(BALLOON_CHUNKS * IDLE_PER_CHUNK)
      cycle += 1
    end
  end
end

run_benchmark(10) do
  GCBalloon.run
end
