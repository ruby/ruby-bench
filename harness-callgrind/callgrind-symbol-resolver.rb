# frozen_string_literal: true
#
# Shared logic for resolving JIT hex addresses in callgrind output files
# using perf map files. Used by both the callgrind harness and the
# standalone resolve-callgrind-symbols.rb script.

# Matches fn=(id) 0xADDRESS or cfn=(id) 0xADDRESS (compressed format).
FN_HEX_RE = /^(c?fn=\(\d+\)\s*)0x([0-9a-fA-F]+)\s*$/

# Matches fn=0xADDRESS or cfn=0xADDRESS (uncompressed format).
FN_HEX_NOCOMPRESS_RE = /^(c?fn=)0x([0-9a-fA-F]+)\s*$/

# Extract the guest PID from a callgrind output file by reading the "pid:"
# header line near the top of the file.
def callgrind_guest_pid(callgrind_file)
  File.foreach(callgrind_file) do |line|
    if (m = line.match(/^pid:\s*(\d+)/))
      return m[1]
    end
  end
  nil
end

# Locate the perf map file for a callgrind output file. Uses the PID
# recorded in the callgrind output header to find the conventional
# /tmp/perf-<pid>.map that YJIT writes when --yjit-perf is enabled.
def find_perf_map(callgrind_file)
  pid = callgrind_guest_pid(callgrind_file)
  return nil unless pid

  path = "/tmp/perf-#{pid}.map"
  path if File.exist?(path)
end

# Parse a perf map file into an array of [start, end, name] entries
# sorted by start address. Each line has the format:
#   <start_hex> <size_hex> <symbol_name>
def parse_perf_map(path)
  entries = []

  File.foreach(path).with_index(1) do |line, lineno|
    line = line.strip
    next if line.empty?

    parts = line.split(nil, 3)
    if parts.length < 3
      warn "callgrind-symbol-resolver: skipping malformed perf map line #{lineno}: #{line.inspect}"
      next
    end

    begin
      start = Integer(parts[0], 16)
      size = Integer(parts[1], 16)
    rescue ArgumentError
      warn "callgrind-symbol-resolver: skipping malformed perf map line #{lineno}: #{line.inspect}"
      next
    end

    entries << [start, start + size, parts[2]]
  end

  entries.sort_by! { |e| e[0] }
  entries
end

# Maximum number of bytes past the end of a perf map entry that an
# address can be and still be attributed to that entry. Callgrind
# records call-site return addresses which point to the instruction
# *after* a call, and JIT compilers may leave small alignment padding
# or metadata gaps between compiled functions. This tolerance covers
# both cases.
PERF_MAP_BOUNDARY_TOLERANCE = 64

# Look up an address in sorted perf map entries using binary search.
# Returns the symbol name if the address falls within a known range,
# or nil if no match is found. When with_offset is true and the address
# is not at the start of the region, the result includes the offset in
# the style of Valgrind's get_fnname_w_offset (e.g., "name+0x1a").
#
# Addresses that fall just past the end of an entry (within
# PERF_MAP_BOUNDARY_TOLERANCE bytes) are attributed to that entry.
# This handles callgrind return addresses and inter-function padding.
def perf_map_lookup(addr, entries, starts, with_offset: false)
  idx = starts.bsearch_index { |s| s > addr }
  idx = idx ? idx - 1 : entries.length - 1
  return nil if idx < 0

  start, end_addr, name = entries[idx]
  if addr >= start && addr < end_addr + PERF_MAP_BOUNDARY_TOLERANCE
    # Only attribute past-the-end addresses when they don't fall inside
    # the next entry (i.e., they are in a gap, not a different function).
    if addr >= end_addr && idx + 1 < entries.length
      next_start = entries[idx + 1][0]
      return nil if addr >= next_start
    end

    offset = addr - start
    if with_offset && offset > 0
      "#{name}+0x#{offset.to_s(16)}"
    else
      name
    end
  end
end

# Resolve JIT hex addresses in a callgrind output file, streaming through
# a temporary file to avoid reading the entire file into memory. Replaces
# hex addresses in fn=/cfn= lines with symbolic names from the perf map
# entries. Returns [resolved_count, unresolved_count], or nil if skipped.
def resolve_callgrind_file(callgrind_file, entries, starts, with_offset: false)
  require "tempfile"

  resolved = 0
  unresolved = 0

  dir = File.dirname(callgrind_file)
  basename = File.basename(callgrind_file)

  Tempfile.create(basename, dir) do |tmp|
    File.foreach(callgrind_file) do |line|
      m = FN_HEX_RE.match(line) || FN_HEX_NOCOMPRESS_RE.match(line)
      if m
        addr = Integer(m[2], 16)
        name = perf_map_lookup(addr, entries, starts, with_offset: with_offset)
        if name
          resolved += 1
          tmp.write("#{m[1]}#{name}\n")
        else
          unresolved += 1
          tmp.write(line)
        end
      else
        tmp.write(line)
      end
    end

    tmp.close
    File.rename(tmp.path, callgrind_file)
  end

  [resolved, unresolved]
end
