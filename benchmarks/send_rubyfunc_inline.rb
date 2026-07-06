require_relative '../harness/loader'

INNER_ITERATIONS = 10_000_000
EXPECTED_RESULT = 2 * INNER_ITERATIONS * INNER_ITERATIONS + 4 * INNER_ITERATIONS

def send_rubyfunc_inline_callee(a, b, c, d)
  a + b + c + d
end

def send_rubyfunc_inline_driver(limit)
  total = 0
  i = 0

  while i < limit
    total += send_rubyfunc_inline_callee(i, i + 1, i + 2, i + 3)
    i += 1
  end

  total
end

100.times do
  $send_rubyfunc_inline_result = send_rubyfunc_inline_driver(100)
end

run_benchmark(20) do
  $send_rubyfunc_inline_result = send_rubyfunc_inline_driver(INNER_ITERATIONS)
end

raise "unexpected result: #{$send_rubyfunc_inline_result}" unless $send_rubyfunc_inline_result == EXPECTED_RESULT
