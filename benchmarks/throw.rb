require_relative '../lib/harness/loader'

def foo
  yield
end

# This generates the throw instruction to exit from the block
# Usage based on what was seen in liquid:
# https://github.com/Shopify/liquid/blob/48cb643c026557f48e524dfd39cc9ff90aa3db95/lib/liquid/context.rb#L247
def bar
  foo { return 1 }
end

run_benchmark(700) do
  i = 0
  while i < 20_000
    # Call 10 times to reduce loop overhead
    bar
    bar
    bar
    bar
    bar
    bar
    bar
    bar
    bar
    bar
    i += 1
  end
end
