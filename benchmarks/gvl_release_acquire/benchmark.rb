require_relative "../../harness/loader"

# Windows has no /dev/zero, so read the same zeros from a regular file kept in data/.
ZERO_PATH = if File.exist?("/dev/zero")
  "/dev/zero"
else
  File.join(__dir__, "data", "zero").tap do |path|
    unless File.size?(path) == 1_000_000
      Dir.mkdir(File.dirname(path)) unless Dir.exist?(File.dirname(path))
      File.binwrite(path, "\0" * 1_000_000)
    end
  end
end.freeze

run_benchmark(5) do |num_rs, ractor_args|
  output = File.open(File::NULL, "wb")
  input = File.open(ZERO_PATH, "rb")
  100_000.times do
    output.write(input.read(10))
  end
end
