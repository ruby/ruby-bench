# frozen_string_literal: true

# Resolved when the harness loads, before use_gemfile. Loading fiddle after Bundler.setup goes through Bundler.reset!,
# which redefines Kernel#gem and invalidates YJIT code if it happens between iterations. A dropped Fiddle::Handle is
# freed by a deferred finalizer, whose interrupt also sends YJIT code back to the interpreter, so kernel32 stays open.
module WindowsMemoryCounters
  begin
    load_fiddle
    @kernel32 = Fiddle.dlopen("kernel32")
    @process = Fiddle::Function.new(@kernel32['GetCurrentProcess'], [], Fiddle::TYPE_VOIDP).call
    @get_info = Fiddle::Function.new(@kernel32['K32GetProcessMemoryInfo'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
  rescue LoadError, Fiddle::DLError, NameError
    warn "Failed to get memory counters: #{$!.message}"
  end

  # The working set of this process and its peak in bytes, the Windows counterparts of RSS and max RSS.
  def self.read
    return nil unless @get_info

    # PROCESS_MEMORY_COUNTERS: two DWORDs followed by eight SIZE_Ts, the first two being PeakWorkingSetSize and WorkingSetSize.
    buffer = "\0".b * (8 + 8 * Fiddle::SIZEOF_SIZE_T)
    buffer[0, 4] = [buffer.bytesize].pack('L')
    return nil if @get_info.call(@process, buffer, buffer.bytesize).zero?

    peak_working_set, working_set = buffer.unpack('x8J2')
    { working_set: working_set, peak_working_set: peak_working_set }
  end
end
