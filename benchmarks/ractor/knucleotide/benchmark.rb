# The Computer Language Benchmarks Game
# https://salsa.debian.org/benchmarksgame-team/benchmarksgame/
#
# k-nucleotide benchmark - Ractor implementation
# Mirrors the Process.fork version structure as closely as possible

require_relative "../../../harness/loader"

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
  }.map! { |seq, count|
    "#{seq} #{'%.3f' % ((count * 100.0) / n)}"
  }.join("\n") << "\n\n"
end

def find_seq(seq, s)
  _, table = frequency(seq, s.length)
  "#{table[s] || 0}\t#{s}\n"
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

  sequence.upcase.freeze
end

# Make sequence shareable for Ractors
TEST_SEQUENCE = Ractor.make_shareable(generate_test_sequence(100_000))

run_benchmark(5) do |num_ractors, ractor_args|
  freqs = [1, 2]
  nucleos = %w(GGT GGTA GGTATT GGTATTTTAATT GGTATTTTAATTTATAGT)

  # Sequential version - mirrors Process version but without Workers
  results = []
  freqs.each { |i| results << sort_by_freq(TEST_SEQUENCE, i) }
  nucleos.each { |s| results << find_seq(TEST_SEQUENCE, s) }
  results
end
