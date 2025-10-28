require_relative "../../harness/loader"

run_benchmark(5) do |num_rs, ractor_args|
  output = File.open("/dev/null", "wb")
  input = File.open("/dev/zero", "rb")
  100_000.times do
    output.write(input.read(10))
  end
end
