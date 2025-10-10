require_relative '../../harness/loader'

# Protoboeuf decoder
require_relative 'benchmark_pb'

Dir.chdir __dir__
FAKE_MSG_BINS = Ractor.make_shareable(Marshal.load(File.binread('encoded_msgs.bin')))

run_benchmark(20) do
  FAKE_MSG_BINS.each { |bin| ProtoBoeuf::ParkingLot.decode bin }
end
