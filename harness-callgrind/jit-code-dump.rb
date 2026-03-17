# frozen_string_literal: true
#
# Dump JIT code regions from the current process to a raw binary file
# and build a minimal ELF shared object that qcachegrind/kcachegrind
# can disassemble.
#
# The dump is driven by the perf map file: each entry gives us the
# start address and size of a compiled function. We read those bytes
# from /proc/self/mem and write them to an output file along with a
# metadata header so the ELF builder knows where to place them.
#
# File format (.jitdump):
#   Header:    "JITDUMP\0"  (8 bytes magic)
#   Per region:
#     start_addr  (8 bytes, little-endian uint64)
#     size        (8 bytes, little-endian uint64)
#     code bytes  (size bytes)
#   Trailer:   "\0" * 16  (sentinel: start=0, size=0)

# Dump JIT code regions listed in a perf map to a .jitdump file by
# reading from /proc/self/mem. Returns the path to the dump file,
# or nil if the dump could not be created.
def dump_jit_code(perf_map_path, dump_path)
  unless File.exist?("/proc/self/mem")
    warn "jit-code-dump: /proc/self/mem not available, skipping JIT code dump."
    return nil
  end

  unless File.exist?(perf_map_path)
    warn "jit-code-dump: perf map #{perf_map_path} not found, skipping JIT code dump."
    return nil
  end

  regions = []
  File.foreach(perf_map_path) do |line|
    parts = line.strip.split(nil, 3)
    next if parts.length < 3

    begin
      start = Integer(parts[0], 16)
      size = Integer(parts[1], 16)
      regions << [start, size]
    rescue ArgumentError
      next
    end
  end

  if regions.empty?
    warn "jit-code-dump: no regions found in perf map, skipping."
    return nil
  end

  regions.sort_by! { |s, _| s }

  mem = File.open("/proc/self/mem", "rb")
  out = File.open(dump_path, "wb")
  out.write("JITDUMP\0")

  dumped = 0
  regions.each do |start, size|
    begin
      mem.seek(start)
      code = mem.read(size)
      if code && code.bytesize == size
        out.write([start, size].pack("Q<Q<"))
        out.write(code)
        dumped += 1
      end
    rescue Errno::EIO, Errno::EFAULT
      # Region not readable (unmapped or protected), skip it.
    end
  end

  # Sentinel trailer.
  out.write("\0" * 16)
  out.close
  mem.close

  warn "jit-code-dump: Dumped #{dumped}/#{regions.length} JIT code regions to #{dump_path}."
  dumped > 0 ? dump_path : nil
end

# Build a minimal ELF64 shared object from a .jitdump file. The ELF
# places code at the original virtual addresses so that qcachegrind
# can disassemble JIT functions when it runs objdump on the file.
#
# The ELF contains:
#   - An ELF header
#   - A single PT_LOAD program header per contiguous code group
#   - The raw code bytes at their file offsets
#   - A .symtab and .strtab with symbols from the perf map
#
# This is a minimal "just enough for objdump -d" ELF, not a fully
# linked shared object.
def build_jit_elf(dump_path, elf_path, perf_map_path = nil)
  unless File.exist?(dump_path)
    warn "jit-code-dump: dump file #{dump_path} not found."
    return nil
  end

  data = File.binread(dump_path)
  unless data.start_with?("JITDUMP\0")
    warn "jit-code-dump: invalid dump file magic."
    return nil
  end

  # Parse regions from the dump.
  regions = []
  pos = 8
  while pos + 16 <= data.bytesize
    start, size = data[pos, 16].unpack("Q<Q<")
    pos += 16
    break if start == 0 && size == 0
    break if pos + size > data.bytesize

    regions << { vaddr: start, size: size, code: data[pos, size] }
    pos += size
  end

  if regions.empty?
    warn "jit-code-dump: no regions in dump file."
    return nil
  end

  # Parse perf map symbols for the .symtab if available.
  symbols = []
  if perf_map_path && File.exist?(perf_map_path)
    File.foreach(perf_map_path) do |line|
      parts = line.strip.split(nil, 3)
      next if parts.length < 3
      begin
        symbols << {
          addr: Integer(parts[0], 16),
          size: Integer(parts[1], 16),
          name: parts[2]
        }
      rescue ArgumentError
        next
      end
    end
  end

  # Group contiguous regions into segments. Regions separated by
  # more than 1 MiB get their own segment to avoid huge sparse files.
  regions.sort_by! { |r| r[:vaddr] }
  segments = []
  current_seg = { regions: [regions[0]] }
  regions[1..].each do |r|
    prev = current_seg[:regions].last
    gap = r[:vaddr] - (prev[:vaddr] + prev[:size])
    if gap > 1024 * 1024
      segments << current_seg
      current_seg = { regions: [r] }
    else
      current_seg[:regions] << r
    end
  end
  segments << current_seg

  # ELF64 constants.
  elfclass64    = 2
  elfdata2lsb   = 1
  ev_current    = 1
  elfosabi_none = 0
  et_dyn        = 3
  em_x86_64     = 62
  pt_load       = 1
  pf_r_x        = 5
  stt_func      = 2
  stb_global    = 1
  shn_abs       = 0xFFF1

  ehdr_size  = 64
  phdr_size  = 56

  # Section headers: null, .text per segment, .shstrtab [, .symtab, .strtab]
  shdr_size  = 64
  num_text_shdrs = segments.length
  num_shdrs  = 1 + num_text_shdrs + 1 + (symbols.empty? ? 0 : 2)  # null + .text* + .shstrtab [+ .symtab + .strtab]
  num_phdrs  = segments.length

  # Layout: ELF header, phdrs, then segment data, then sections at the end.
  phdrs_offset = ehdr_size
  data_offset = phdrs_offset + num_phdrs * phdr_size

  # Align data offset to 16 bytes.
  data_offset = (data_offset + 15) & ~15

  # Calculate file offsets for each segment's data.
  file_pos = data_offset
  segments.each do |seg|
    first_vaddr = seg[:regions].first[:vaddr]
    last = seg[:regions].last
    seg_end = last[:vaddr] + last[:size]
    seg[:vaddr] = first_vaddr
    seg[:memsz] = seg_end - first_vaddr
    seg[:file_offset] = file_pos

    # Build the segment data with gaps filled by zeros.
    seg_data = String.new(encoding: Encoding::BINARY)
    seg[:regions].each do |r|
      padding = r[:vaddr] - (first_vaddr + seg_data.bytesize)
      seg_data << ("\0".b * padding) if padding > 0
      seg_data << r[:code]
    end
    seg[:data] = seg_data
    seg[:filesz] = seg_data.bytesize

    file_pos += seg_data.bytesize
  end

  # Align to 8 bytes before sections.
  file_pos = (file_pos + 7) & ~7

  # Build .shstrtab.
  shstrtab = "\0".b
  text_name_idx = shstrtab.bytesize
  shstrtab << ".text\0".b
  shstrtab_name_idx = shstrtab.bytesize
  shstrtab << ".shstrtab\0".b
  symtab_name_idx = nil
  strtab_name_idx = nil
  unless symbols.empty?
    symtab_name_idx = shstrtab.bytesize
    shstrtab << ".symtab\0".b
    strtab_name_idx = shstrtab.bytesize
    shstrtab << ".strtab\0".b
  end

  # Build .strtab and .symtab.
  strtab = nil
  symtab = nil
  unless symbols.empty?
    strtab = "\0".b
    # Null symbol entry (st_name + st_info + st_other + st_shndx + st_value + st_size = 24 bytes).
    symtab = "\0".b * 24

    symbols.each do |sym|
      name_offset = strtab.bytesize
      strtab << "#{sym[:name]}\0".b

      # Find which .text section this symbol belongs to (section indices 1..N).
      shndx = shn_abs
      segments.each_with_index do |seg, i|
        if sym[:addr] >= seg[:vaddr] && sym[:addr] < seg[:vaddr] + seg[:memsz]
          shndx = i + 1  # .text sections start at index 1
          break
        end
      end

      # Elf64_Sym: st_name(4) st_info(1) st_other(1) st_shndx(2) st_value(8) st_size(8)
      info = (stb_global << 4) | stt_func
      symtab << [name_offset, info, 0, shndx, sym[:addr], sym[:size]].pack("VCCvQ<Q<")
    end
  end

  # Section header table.
  shdrs_offset = file_pos
  shstrtab_offset = shdrs_offset + num_shdrs * shdr_size

  # Recalculate positions for symtab/strtab after shstrtab.
  strtab_offset = shstrtab_offset + shstrtab.bytesize
  strtab_offset = (strtab_offset + 7) & ~7 unless symbols.empty?
  symtab_offset = symbols.empty? ? 0 : strtab_offset + strtab.bytesize
  symtab_offset = (symtab_offset + 7) & ~7 unless symbols.empty?

  # Section indices: [0]=null, [1..N]=.text, [N+1]=.shstrtab, [N+2]=.symtab, [N+3]=.strtab
  shstrtab_idx = 1 + num_text_shdrs
  symtab_idx = symbols.empty? ? 0 : shstrtab_idx + 1
  strtab_idx = symbols.empty? ? 0 : shstrtab_idx + 2

  # Build ELF header.
  elf = String.new(encoding: Encoding::BINARY)
  elf << "\x7FELF".b                         # e_ident[EI_MAG]
  elf << [elfclass64].pack("C")              # EI_CLASS
  elf << [elfdata2lsb].pack("C")             # EI_DATA
  elf << [ev_current].pack("C")              # EI_VERSION
  elf << [elfosabi_none].pack("C")           # EI_OSABI
  elf << ("\0".b * 8)                        # EI_ABIVERSION + padding
  elf << [et_dyn].pack("v")                  # e_type
  elf << [em_x86_64].pack("v")              # e_machine
  elf << [ev_current].pack("V")              # e_version
  elf << [0].pack("Q<")                      # e_entry
  elf << [phdrs_offset].pack("Q<")           # e_phoff
  elf << [shdrs_offset].pack("Q<")           # e_shoff
  elf << [0].pack("V")                       # e_flags
  elf << [ehdr_size].pack("v")               # e_ehsize
  elf << [phdr_size].pack("v")               # e_phentsize
  elf << [num_phdrs].pack("v")               # e_phnum
  elf << [shdr_size].pack("v")               # e_shentsize
  elf << [num_shdrs].pack("v")               # e_shnum
  elf << [shstrtab_idx].pack("v")            # e_shstrndx

  # Program headers.
  segments.each do |seg|
    elf << [pt_load].pack("V")               # p_type
    elf << [pf_r_x].pack("V")               # p_flags
    elf << [seg[:file_offset]].pack("Q<")    # p_offset
    elf << [seg[:vaddr]].pack("Q<")          # p_vaddr
    elf << [seg[:vaddr]].pack("Q<")          # p_paddr
    elf << [seg[:filesz]].pack("Q<")         # p_filesz
    elf << [seg[:memsz]].pack("Q<")          # p_memsz
    elf << [0x1000].pack("Q<")               # p_align
  end

  # Pad to data offset.
  elf << ("\0".b * (data_offset - elf.bytesize))

  # Segment data.
  segments.each do |seg|
    elf << seg[:data]
  end

  # Pad to section headers.
  elf << ("\0".b * (shdrs_offset - elf.bytesize))

  # Section headers.
  sht_null    = 0
  sht_progbits = 1
  sht_symtab  = 2
  sht_strtab  = 3
  shf_alloc   = 2
  shf_execinstr = 4

  # [0] SHT_NULL
  elf << ("\0".b * shdr_size)

  # [1..N] .text sections — one per segment so objdump can find the code.
  segments.each do |seg|
    elf << [text_name_idx].pack("V")           # sh_name (.text)
    elf << [sht_progbits].pack("V")            # sh_type
    elf << [shf_alloc | shf_execinstr].pack("Q<") # sh_flags
    elf << [seg[:vaddr]].pack("Q<")            # sh_addr
    elf << [seg[:file_offset]].pack("Q<")      # sh_offset
    elf << [seg[:filesz]].pack("Q<")           # sh_size
    elf << [0].pack("V")                       # sh_link
    elf << [0].pack("V")                       # sh_info
    elf << [16].pack("Q<")                     # sh_addralign
    elf << [0].pack("Q<")                      # sh_entsize
  end

  # [N+1] .shstrtab (SHT_STRTAB)
  elf << [shstrtab_name_idx].pack("V")        # sh_name
  elf << [sht_strtab].pack("V")               # sh_type
  elf << [0].pack("Q<")                        # sh_flags
  elf << [0].pack("Q<")                        # sh_addr
  elf << [shstrtab_offset].pack("Q<")          # sh_offset
  elf << [shstrtab.bytesize].pack("Q<")        # sh_size
  elf << [0].pack("V")                         # sh_link
  elf << [0].pack("V")                         # sh_info
  elf << [1].pack("Q<")                        # sh_addralign
  elf << [0].pack("Q<")                        # sh_entsize

  unless symbols.empty?
    # [N+2] .symtab (SHT_SYMTAB)
    elf << [symtab_name_idx].pack("V")         # sh_name
    elf << [sht_symtab].pack("V")              # sh_type
    elf << [0].pack("Q<")                       # sh_flags
    elf << [0].pack("Q<")                       # sh_addr
    elf << [symtab_offset].pack("Q<")           # sh_offset
    elf << [symtab.bytesize].pack("Q<")         # sh_size
    elf << [strtab_idx].pack("V")               # sh_link = .strtab index
    elf << [1].pack("V")                        # sh_info = first non-local symbol
    elf << [8].pack("Q<")                       # sh_addralign
    elf << [24].pack("Q<")                      # sh_entsize = sizeof(Elf64_Sym)

    # [N+3] .strtab (SHT_STRTAB)
    elf << [strtab_name_idx].pack("V")         # sh_name
    elf << [sht_strtab].pack("V")              # sh_type
    elf << [0].pack("Q<")                       # sh_flags
    elf << [0].pack("Q<")                       # sh_addr
    elf << [strtab_offset].pack("Q<")           # sh_offset
    elf << [strtab.bytesize].pack("Q<")         # sh_size
    elf << [0].pack("V")                        # sh_link
    elf << [0].pack("V")                        # sh_info
    elf << [1].pack("Q<")                       # sh_addralign
    elf << [0].pack("Q<")                       # sh_entsize
  end

  # Write .shstrtab content.
  elf << shstrtab

  unless symbols.empty?
    # Pad and write .strtab.
    elf << ("\0".b * (strtab_offset - elf.bytesize)) if elf.bytesize < strtab_offset
    elf << strtab

    # Pad and write .symtab.
    elf << ("\0".b * (symtab_offset - elf.bytesize)) if elf.bytesize < symtab_offset
    elf << symtab
  end

  File.binwrite(elf_path, elf)
  warn "jit-code-dump: Built ELF #{elf_path} (#{segments.length} segments, #{symbols.length} symbols, #{elf.bytesize} bytes)."
  elf_path
end

# Patch a callgrind output file to set the ob= (object) field for JIT
# functions to point to the ELF file. This tells qcachegrind where to
# find the binary for disassembly.
#
# JIT functions are identified by having no ob= or an ob= of "???" or
# similar. We detect them by checking if their fn= address falls within
# the perf map range.
def patch_callgrind_object(callgrind_file, elf_path, perf_map_path)
  require "tempfile"
  require_relative "callgrind-symbol-resolver"

  entries = parse_perf_map(perf_map_path)
  return if entries.empty?

  min_addr = entries.first[0]
  max_addr = entries.last[1]

  # Track the current ob= context and whether we're in a JIT function.
  current_ob = nil
  in_jit_fn = false
  elf_ob_line = "ob=#{File.expand_path(elf_path)}\n"

  dir = File.dirname(callgrind_file)
  basename = File.basename(callgrind_file)

  Tempfile.create(basename, dir) do |tmp|
    File.foreach(callgrind_file) do |line|
      if line.start_with?("ob=")
        current_ob = line
        tmp.write(line)
      elsif line.match?(/^fn=/)
        # Check if this function is a JIT function by looking for a
        # resolved zjit:: prefix or an address in the JIT range.
        if line.include?("zjit::") || line.include?("yjit::")
          in_jit_fn = true
          # Inject ob= for the JIT ELF before this fn= line.
          tmp.write(elf_ob_line) unless current_ob == elf_ob_line
          current_ob = elf_ob_line
        else
          in_jit_fn = false
        end
        tmp.write(line)
      else
        tmp.write(line)
      end
    end

    tmp.close
    File.rename(tmp.path, callgrind_file)
  end
end
