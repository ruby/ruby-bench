require_relative '../harness/loader'

# XOR strings in place
# Expected to behave like Xorcist.xor! from the xorcist gem
# https://github.com/fny/xorcist/tree/master
#
# This is a test of the performance of low-level operations in Ruby,
# it is written to try and get the maximum possible performance with YJIT,
# it is not trying to look like idiomatic Ruby code.
#
def ruby_xor!(a, b)
  if !a.is_a? String or !b.is_a? String
    raise 'expected two string arguments'
  end

  l = a.bytesize
  lb = b.bytesize
  if lb < l
    l = lb
  end

  i = 0
  while i < l
    ba = a.getbyte(i)
    bb = b.getbyte(i)
    a.setbyte(i, ba ^ bb)
    i = i.succ
  end

  a
end

A = 'this is a long string with no useful contents yada yada yada yada'.freeze
B = 'this is also a long string with no useful contents yada yada daaaaaa'.freeze

run_benchmark(20) do
  a = A
  b = B
  for i in 0...20_000
    ruby_xor!(a.dup, b)
  end
end

# Do a correctness check, outside of the hot path
out = ruby_xor!(A.dup, B)

if out != "\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000L\u001F\u0000N\u0006\u0000\u001F\e\u001C\u000EN\u0014T\u0005\u0000\u001A\u000F\u0000\u0019\u0006T\u001DS\v\tU\u0019S\u0006\t\e\u0018E\r\e\u001DT\u001C\u000F\u0010\u0012\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u001D\u0000\u0005\u0000"
  raise "incorrect output"
end
