# frozen_string_literal: true

require "etc"
require "open3"

module BenchmarkMode
  BENCH_SET = "bench"
  OTHER_SET = "other"

  module Helpers
    extend self

    # Transform a list like "0,2-4,7" into an array of integers.
    def list_to_ints(list)
      list
        &.split(',')
        &.flat_map { |s| a, b = s.split('-').map(&:to_i); b ? a.upto(b).to_a : [a] }
    end
  end

  class << self
    # Enable all available settings.
    def engage!(nice: nil)
      # Set scheduler priority ("niceness") for this process (and any child processes).
      Nice.renice_process_group!(nice || -15, Process.getpgrp)

      return unless bench_cpus = find_bench_cpus

      # Create "bench" cpuset for our task (and forks).
      bench_tasks = [$$]
      CpuSet.new(BENCH_SET, cpus: bench_cpus, tasks: bench_tasks, sched_load_balance: '0').create

      # Put all other tasks in "other" cpuset.
      other_tasks = all_tasks - bench_tasks
      other_cpus = all_cpus - bench_cpus
      CpuSet.new(OTHER_SET, cpus: other_cpus, tasks: other_tasks).create

      # Disable the hyper thread siblings of our CPUs
      # so that nothing gets put on the physical core we are using.
      @hyper_thread_siblings = []
      bench_cpus.each do |cpu|
        @hyper_thread_siblings.concat(HyperThreading.new(cpu:).disable)
      end

      # Pin current task (coordinator) to first CPU
      # so the benchmarks can run alone on the second.
      CpuAffinity.pin!(bench_cpus.first, $$)

      bench_cpus.last
    end
    alias enable! engage!

    # Restore settings to their defaults.
    def disengage!
      [OTHER_SET, BENCH_SET].each do |set|
        CpuSet.new(set).destroy
      end

      # If we know which ones we took offline, restore those.
      if @hyper_thread_siblings&.any?
        @hyper_thread_siblings.each do |sib|
          CPU.enable(sib)
        end
      else
        # Otherwise just re-enable all CPUs.
        Sudo.write(Dir.glob("#{CPU::ROOT}/cpu*/online"), 1)
      end

      # Don't return the above value.
      nil
    end
    alias disable! disengage!

    # Get thread id's of all running processes.
    def all_tasks
      # In cgroup v2 the task list doesn't necessarily include all thread id's.
      (CpuSet.tasks + "\n" + `ps -eo tid=`).lines.map(&:strip).map(&:to_i).uniq
    end

    # Get list of all cpu numbers.
    def all_cpus
      return @all_cpus if defined?(@all_cpus)

      # Read from root cpuset so our view is not limited by any current cpuset.
      @all_cpus = Helpers.list_to_ints(CpuSet.cpus)

      # If that didn't work just guess at it.
      @all_cpus ||= (0 ... Etc.nprocessors).to_a
    end

    # Determine which cpu numbers to use for benchmarking.
    # TODO: look at cpus in use, grab the ones with the least amount of (kernel) tasks?
    def find_bench_cpus
      # If we have enough CPUs, just pick some:
      # one for the coordinator
      # one for the actual benchmarks
      [1, 2] if all_cpus.size > 4
    end
  end

  # Wrapper functions to enable commands to be run as root
  # without requiring the whole benchmark suite to have been started by root.
  module Sudo
    extend self

    def log(msg)
      STDERR.puts msg
    end

    # Run command with escalated privileges.
    def sudo(*command, **kwargs)
      log "$ sudo #{command.join(" ")}"
      system("sudo", *command, **kwargs)
    end

    # Write file with escalated privileges.
    def write(path, content, verbose: true)
      content = content.to_s

      # Limit to X items at a time to avoid command line argument limits.
      Array(path).select { |p| File.exist?(p) }.each_slice(50) do |paths|
        cmd = ["sudo", "tee", *paths]
        if verbose
          log "$ echo #{content} | sudo #{cmd.join(" ")}"
        end

        Open3.popen3(*cmd) do |stdin, stdout, stderr, thread|
          stdin.write(content)
          stdin.close

          err = stderr.read.strip
          if !err.empty? && err !~ /No such process|Invalid argument/
            if !verbose
              log "$ echo #{content} | sudo #{cmd.join(" ")}"
            end
            puts err
          end
        end
      end
    end
  end

  # Manage whether CPUs are on or offline.
  class CPU
    ROOT = "/sys/devices/system/cpu"

    class << self
      include Sudo

      def enable(n)
        set(n, :online, 1)
      end

      def disable(n)
        set(n, :online, 0)
      end

      def set(n, key, val)
        write("#{ROOT}/cpu#{n}/#{key}", val)
      end
    end
  end

  # Manage cpu hyper-threading.
  # If we want to pin our benchmarks to a single cpu,
  # we disable the hyper-threading sibling cpu
  # so that another process can't use (even the thread sibling of) that cpu.
  class HyperThreading
    attr_reader :cpu

    def initialize(cpu:)
      @cpu = cpu
    end

    def list_path
      "#{CPU::ROOT}/cpu#{cpu}/topology/thread_siblings_list"
    end

    # Take sibling CPUs offline and return the list of modified CPUs.
    def disable
      altered = []

      if File.exist?(list_path)
        siblings = Helpers.list_to_ints(File.read(list_path))
        siblings.each do |sib|
          next if sib == cpu

          altered << sib
          CPU.disable(sib)
        end
      end

      altered
    end
  end

  # Manage (cgroup) cpusets to limit tasks to specified cpus.
  class CpuSet
    include Sudo

    # If cgroup v2 is mounted (systemd unified hierarchy) but not managing
    # cpusets we can mount them and use them in the old fashion.
    # If cgroup v2 is managing cpusets we can integrate with the already mounted fs.
    # If cpusets aren't being managed by v2 you can enable it with:
    # echo +cpuset | sudo tee /sys/fs/cgroup/cgroup.subtree_control
    # (provided you don't have a cpusets mount somewhere else).

    CGROUP_V2_ROOT = "/sys/fs/cgroup"

    # Man cpuset(7) says "/dev/cpuset" but mounting there may fail when /dev is a devtmpfs.
    DEFAULT_ROOT = "/cpusets"

    def self.find_root
      return @root if defined?(@root)

      unless File.read("/proc/filesystems").lines.detect { |line| line =~ /^nodev\s+cpuset$/ }
        return @root = nil
      end

      # If it's already mounted use the current path.
      File.read("/proc/mounts").lines.each do |line|
        if %r{^\S+ (?<mountpoint>/\S+) cgroup (?:[^ ]*,)?cpuset[, ]} =~ line
          return @root = mountpoint
        end
      end

      if read("cgroup.subtree_control", CGROUP_V2_ROOT)&.split(' ')&.include?('cpuset')
        @cgroup_v2 = true
        return @root = CGROUP_V2_ROOT
      end

      @root = DEFAULT_ROOT.then do |dir|
        Sudo.sudo("mkdir", "-p", dir) unless File.exist?(dir)

        Sudo.sudo("mount", "-t", "cpuset", "none", dir)

        # If the fs failed to mount, return nil.
        dir if File.exist?(self.file_path(:tasks, dir))
      end
    end

    V2_PATHS = {
      cpu_exclusive: "cpuset.cpus.exclusive",
      cpus: "cpuset.cpus",
      effective_cpus: "cpuset.cpus.effective",
      effective_mems: "cpuset.mems.effective",
      mems: "cpuset.mems",
      sched_load_balance: nil, # not available in the v2 fs
      tasks: "cgroup.procs",
    }

    def self.file_path(name, dir = nil)
      dir ||= find_root
      name = V2_PATHS.fetch(name) if cgroup_v2?

      return unless name

      File.join(dir, name.to_s)
    end

    def self.read(name, dir = nil)
      path = file_path(name, dir)

      return unless path && File.exist?(path)

      File.read(path)
    end

    def self.cgroup_v2?
      @cgroup_v2
    end

    def self.cpus
      read(:effective_cpus)&.strip
    end

    def self.mems
      read(:effective_mems)&.strip
    end

    def self.tasks
      read(:tasks)
    end

    def initialize(name, cpus: nil, tasks: [], **kwargs)
      @name = name
      @cpus = cpus
      @tasks = tasks
      @settings = {cpu_exclusive: 1, cpus: Array(cpus).join(",")}.merge(kwargs)
    end

    # Returns "root/name" if root is defined.
    def path
      return @path if defined?(@path)

      @path = self.class.find_root&.then { |root| File.join(root, @name) }
    end

    # Create directory and write settings to files beneath it.
    def create
      return unless path

      unless File.directory?(path)
        sudo("mkdir", path)
      end

      # Both cpus and mems must be set in order to add tasks.
      # Default mems to the root value.
      @settings[:mems] ||= self.class.mems

      # Settings must be written before tasks can be added.
      @settings.each_pair do |key, value|
        write_setting(key, value)
      end

      # Now we can write the tasks.
      write_setting(:tasks, @tasks, verbose: false)
    end

    def write_setting(key, value, verbose: true)
      key_path = self.class.file_path(key, path)
      return unless key_path

      # If an array is provided (for "tasks") write each item individually.
      Array(value).each do |item|
        write(key_path, item, verbose:)
      end
    end

    # Move tasks out of cpuset and remove directory.
    def destroy
      return unless path && File.directory?(path)

      # Move tasks to parent cpuset as we cannot remove a set that still has tasks.
      root_tasks = self.class.file_path(:tasks)
      File.read(self.class.file_path(:tasks, path)).lines.each do |tid|
        write(root_tasks, tid, verbose: false)
      end

      sudo("rmdir", path)
    end
  end

  # Modify scheduling priority (niceness).
  module Nice
    class << self
      include Sudo

      # Allow setting a negative priority without
      # needing this process (or any child) to have been launched by root.
      def renice_process_group!(priority, group)
        sudo("renice", priority.to_s, "-g", group.to_s)
      end
    end
  end

  # Set CPU affinity to pin a task to a cpu.
  module CpuAffinity
    class << self
      include Sudo

      def pin!(cpu, pid)
        # The "p" and "c" options must be grouped together.
        sudo("taskset", "-pc", cpu.to_s, pid.to_s)
      end
    end
  end
end
