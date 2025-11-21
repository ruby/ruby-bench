# The Computer Language Benchmarks Game
# https://salsa.debian.org/benchmarksgame-team/benchmarksgame/
#
# k-nucleotide benchmark - Fastest implementation
# Based on Ruby #1 with byteslice optimization

require_relative '../../lib/harness/loader'

def frequency(seq, length)
  frequencies = Hash.new(0)
  last_index = seq.length - length

  i = 0
  while i <= last_index
    frequencies[seq.byteslice(i, length)] += 1
    i += 1
  end

  [seq.length - length + 1, frequencies]
end

def sort_by_freq(seq, length)
  n, table = frequency(seq, length)

  table.sort { |a, b|
    cmp = b[1] <=> a[1]
    cmp == 0 ? a[0] <=> b[0] : cmp
  }.map { |seq, count|
    "#{seq} #{'%.3f' % ((count * 100.0) / n)}"
  }.join("\n") + "\n\n"
end

def find_seq(seq, s)
  n, table = frequency(seq, s.length)
  "#{table[s] || 0}\t#{s}\n"
end

class Worker
  def initialize(&block)
    @r, @w = IO.pipe
    @p = Process.fork do
      @r.close
      @w.write yield
      @w.close
    end
    @w.close
  end

  def result
    ret = @r.read
    @r.close
    Process.wait(@p)
    ret
  end
end

def generate_test_sequence(size)
  alu = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCA" +
        "GGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGG" +
        "TGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTT" +
        "GCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA"

  sequence = ""
  full_copies = size / alu.length
  remainder = size % alu.length

  full_copies.times { sequence << alu }
  sequence << alu[0, remainder] if remainder > 0

  sequence.upcase
end

TEST_SEQUENCE = generate_test_sequence(100_000)

run_benchmark(5) do
  freqs = [1, 2]
  nucleos = %w(GGT GGTA GGTATT GGTATTTTAATT GGTATTTTAATTTATAGT)

  # Parallel processing with Process.fork
  workers = freqs.map { |i| Worker.new { sort_by_freq(TEST_SEQUENCE, i) } }
  workers += nucleos.map { |s| Worker.new { find_seq(TEST_SEQUENCE, s) } }

  # Collect results
  results = workers.map(&:result)

  # Process for benchmark harness
  results
end