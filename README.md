ruby-bench
==========

Small set of benchmarks and scripts for the Ruby programming language.

The benchmarks are found in the `benchmarks` directory. Individual Ruby files
in `benchmarks` are microbenchmarks. Subdirectories under `benchmarks` are
larger macrobenchmarks. Each benchmark relies on a harness found in
[./harness/harness.rb](harness/harness.rb). The harness controls the number of times a benchmark is
run, and writes timing values into an output file.

The `run_benchmarks.rb` script (optional) traverses the `benchmarks` directory and
runs the benchmarks in there. It reads the
output file written by the benchmarking harness. The output is written to
multiple files at the end -- CSV, text and JSON -- so that results can be easily viewed or
graphed in any spreadsheet editor.

## Installation

Clone this repository:
```
git clone https://github.com/ruby/ruby-bench
```

### Benchmarking YJIT

ruby-bench supports benchmarking any Ruby implementation. But if you want to benchmark YJIT,
follow [these instructions](https://github.com/ruby/ruby/blob/master/doc/yjit/yjit.md#building-yjit)
to build and install YJIT.

If you install it with the name `ruby-yjit` on [chruby](https://github.com/postmodern/chruby),
you should enable it before running `./run_benchmarks.rb`:

```
chruby ruby-yjit
```

## Usage

To run all the benchmarks and record the data:
```
cd ruby-bench
./run_benchmarks.rb
```

This runs for a few minutes and produces a table like this in the console (results below not up to date):
```
-------------  -----------  ----------  ---------  ----------  -----------  ------------
bench          interp (ms)  stddev (%)  yjit (ms)  stddev (%)  interp/yjit  yjit 1st itr
30k_ifelse     2372.0       0.0         447.6      0.1         5.30         4.16
30k_methods    6328.3       0.0         963.4      0.0         6.57         6.25
activerecord   171.7        0.8         144.2      0.7         1.19         1.15
binarytrees    445.8        2.1         389.5      2.5         1.14         1.14
cfunc_itself   105.7        0.2         58.7       0.7         1.80         1.80
fannkuchredux  6697.3       0.1         6714.4     0.1         1.00         1.00
fib            245.3        0.1         77.1       0.4         3.18         3.19
getivar        97.3         0.9         44.3       0.6         2.19         0.98
lee            1269.7       0.9         1172.9     1.0         1.08         1.08
liquid-render  204.5        1.0         172.4      1.3         1.19         1.18
nbody          121.9        0.1         121.6      0.3         1.00         1.00
optcarrot      6260.2       0.5         4723.1     0.3         1.33         1.33
railsbench     3827.9       0.9         3581.3     1.3         1.07         1.05
respond_to     259.0        0.6         197.1      0.4         1.31         1.31
setivar        73.1         0.2         53.3       0.7         1.37         1.00
-------------  -----------  ----------  ---------  ----------  -----------  ------------
```

The `interp/yjit` column is the ratio of the average time taken by the interpreter over the
average time taken by YJIT after a number of warmup iterations. Results above 1 represent
speedups. For instance, 1.14 means "YJIT is 1.14 times as fast as the interpreter".

### Specific categories

By default, `run_benchmarks.rb` runs all three [benchmark categories](./benchmarks.yml),
`--category headline,other,micro`. You can run only benchmarks with specific categories:

```
./run_benchmarks.rb --category micro
```

You can also only the headline benchmarks with the `--headline` option:

```
./run_benchmarks.rb --headline
```

### Specific benchmarks

To run one or more specific benchmarks and record the data:
```
./run_benchmarks.rb fib lee optcarrot
```

### Running a single benchmark

This is the easiest way to run a single benchmark.
It requires no setup at all and assumes nothing about the Ruby you are benchmarking.
It's also convenient for profiling, debugging, etc, especially since all benchmarked code runs in that process.

```
ruby benchmarks/some_benchmark.rb
```

### Benchmark organization

Benchmarks can be organized in three ways:

1. **Standalone .rb files** - Place a `.rb` file directly in the `benchmarks/` directory:
   ```
   benchmarks/fib.rb         # Benchmark name: "fib"
   ```

2. **Single benchmark per directory** - For benchmarks that need additional files (like Gemfiles):
   ```
   benchmarks/erubi/
     benchmark.rb            # Benchmark name: "erubi"
     Gemfile
   ```

3. **Multiple benchmarks per directory** - For related benchmarks sharing dependencies:
   ```
   benchmarks/addressable/
     equality.rb             # Benchmark name: "addressable-equality"
     join.rb                 # Benchmark name: "addressable-join"
     Gemfile                 # Shared Gemfile
   ```

   In directories **without** a `benchmark.rb` file, all `.rb` files will be discovered as separate benchmarks.
   The benchmark name is derived as `directoryname-suffix` from `suffix.rb` files.

## Ractor Benchmarks

ruby-bench supports Ractor-specific benchmarking with dedicated categories and benchmark directories.

### Ractor Categories

There are two Ractor-related categories:

* **`--category ractor`** - Runs both regular benchmarks marked with `ractor:
  true` in `benchmarks.yml` AND all benchmarks from the `benchmarks-ractor`
  directory. The `harness-ractor` harness is used for both types of benchmark.

* **`--category ractor-only`** - Runs ONLY benchmarks from the
  `benchmarks-ractor` directory, ignoring regular benchmarks even if they are
  marked with `ractor: true`. This category also automatically uses the
  `harness-ractor` harness.

### Directory Structure

The `benchmarks-ractor/` directory sits at the same level as the main
`benchmarks` directory, and contains Ractor-specific benchmark
implementations that are designed to test Ractor functionality. They are not
intended to be used with any harness except `harness-ractor`.

### Usage Examples

```bash
# Run all Ractor-capable benchmarks (both regular and Ractor-specific)
./run_benchmarks.rb --category ractor

# Run only dedicated Ractor benchmarks from benchmarks-ractor directory
./run_benchmarks.rb --category ractor-only
```

Note: The `harness-ractor` harness is automatically selected when using these
categories, so there's no need to specify `--harness` manually.

### Ractor counts

The Ractor harness measures each benchmark at 0 (the main Ractor only), 1, 2,
4, 6, and 8 Ractors. Set `RUBY_BENCH_RACTORS` to a comma-separated list to
change the counts, for example `RUBY_BENCH_RACTORS=0,2,8`.

`run_benchmarks.rb` starts a fresh process for each count. Heap pages, the GC
page pool, and JIT state therefore cannot carry over from one count to the
next. Each process runs `WARMUP_ITRS` warmup iterations at its own count
before the measured iterations. As in the default harness, the harness prints
each warmup iteration and records its time.

The JSON output keeps one blob per benchmark. `warmup_by_ractors`,
`bench_by_ractors`, and `gc_by_ractors` hold the measurements for each count.
`warmup_by_ractors` holds wall times only. The `--ractor-gc` mode does not
keep GC samples for warmup iterations. `results_by_ractors` holds the
process-level data of each count: `rss`, `maxrss`, YJIT or ZJIT stats, and
`command_line`. The blob has no top-level `rss`, `maxrss`, or JIT stats,
because no single process ran all counts.

The text summary, the CSV output, and `misc/zjit_diff.rb` show one row for
each count, with the RSS and JIT stats of that count's process.

When you run a benchmark directly with `-Iharness-ractor`, the harness runs
all counts in one process, one count after another.

### Ractor Scenario Benchmarks

By default, `harness-ractor` spawns the worker Ractors and runs the benchmark
block inside each of them. A benchmark that calls
`run_benchmark(n, scenario: true)` uses scenario mode instead. The harness
calls the block one time per trial in the main Ractor, with the Ractor count as
its argument. The block spawns and coordinates its own Ractors. When the block
returns a proc, the harness calls the proc after the retention measurement.

Scenario mode skips Ractor count 0 and runs no warmup. For each trial, the
harness records:

* the time of the block call, which includes all work in the block;
* the retained RSS: the RSS after a full GC, minus the RSS of the process
  before the first trial;
* the peak RSS: the highest RSS that the harness reads just before the block
  call, every 5 ms during it (`RACTOR_MEM_PEAK_SAMPLE_INTERVAL`), and just
  after it.

`run_benchmarks.rb` runs a scenario benchmark in one process per count, like
other Ractor benchmarks. It starts no count-0 process when the benchmark's
`benchmarks.yml` entry sets `ractor_scenario: true`; without that key, the
count-0 process fails. Each process measures retained RSS against its own
base RSS, so the JSON output keeps `ractor_mem_base_rss` in
`results_by_ractors`.

Three benchmarks use scenario mode to measure pathological memory behaviour
with multiple ractors, for GC work that reclaims ractor-local memory:

* **`ractor-dead-set`** - Every ractor builds a large live set and terminates.
  Retention shows how much of the dead ractors' final live sets a full GC
  leaves resident.
* **`ractor-idle-garbage`** - Every ractor builds a large set, drops all
  references, then idles without allocating. The garbage cannot be swept
  while the ractor idles.
* **`ractor-msg-backlog`** - Unshareable payloads flood the queues of gated
  consumer ractors, duplicating the payload data per consumer. Its time
  includes the gate sleep (`RACTOR_BACKLOG_GATE_SLEEP`, default 1 second).

```bash
ruby -Iharness-ractor benchmarks/ractor-dead-set/benchmark.rb
```
The harness prints `BENCH_METRIC retained_mib=<worst count median>` and
`BENCH_METRIC peak_mib=...` lines, plus one pair per ractor count. The JSON
fields `ractor_mem_medians` and `ractor_mem_samples` hold the same data. The
summary table of `run_benchmarks.rb` does not show it. The ractor counts and
trials are controlled with `RUBY_BENCH_RACTORS` (default `1,2,4,6,8`) and
`MIN_BENCH_ITRS` (default 3 for these benchmarks).

The harness collects with `GC.start(global: true)` when the target Ruby's
`GC.start` accepts the `global:` keyword. Some Ruby 4.1 builds do not accept it.
On a target with Ractor-local GC, a plain `GC.start` collects only the main
Ractor's object space. The JSON field `ractor_mem_settle` records `global` or
`default`.

With `--ractor-gc` (`RUBY_BENCH_RACTOR_GC=1`), the harness cannot see which
Ractors are workers. A scenario wraps each worker body in
`measure_worker_gc { ... }`, which returns `[result, sample]`. The main Ractor
passes each sample to `record_worker_gc(worker_index, sample)`. A trial fails
when its recorded worker indexes are not `0...count`.

Worker samples cover only the workers' own object spaces during the scenario.
They do not include allocation by the main Ractor, such as the payloads that
`ractor-msg-backlog` sends. They also do not include the GCs that the harness
runs to measure retention. The JSON field `gc_controller_samples` covers the
main Ractor during the scenario.

## Ruby options

By default, ruby-bench benchmarks the Ruby used for `run_benchmarks.rb`.
If the Ruby has `--yjit` option, it compares two Ruby commands, `-e "interp::ruby"` and `-e "yjit::ruby --yjit`.
However, if you specify `-e` yourself, you can override what Ruby is benchmarked.

```sh
# "xxx::" prefix can be used to specify a shorter name/alias, but it's optional.
./run_benchmarks.rb -e "ruby" -e "yjit::ruby --yjit"

# You could also measure only a single Ruby
./run_benchmarks.rb -e "3.1.0::/opt/rubies/3.1.0/bin/ruby"

# With --chruby, you can easily specify rubies managed by chruby
./run_benchmarks.rb --chruby "3.1.0" --chruby "3.1.0+YJIT::3.1.0 --yjit"

# ";" can be used to specify multiple executables in a single option
./run_benchmarks.rb --chruby "3.1.0;3.1.0+YJIT::3.1.0 --yjit"
```

### YJIT options

You can use `--yjit_opts` to specify YJIT command-line options:

```
./run_benchmarks.rb --yjit_opts="--yjit-version-limit=10" fib lee optcarrot
```

### Running pre-init code

It is possible to use `run_benchmarks.rb` to run arbitrary code before
each benchmark run using the `--with-pre-init` option.

For example: to run benchmarks with `GC.auto_compact` enabled a
`pre-init.rb` file can be created, containing `GC.auto_compact=true`,
and this can be passed into the benchmarks in the following way:

```
./run_benchmarks.rb --with-pre-init=./pre-init.rb
```

This file will then be passed to the underlying Ruby interpreter with
`-r`.

## Harnesses

You can find several test harnesses in this repository:

* harness - the normal default harness, with duration controlled by warmup iterations and time/count limits
* harness-bips - a harness that measures iterations/second until stable
* harness-continuous - a harness that adjusts the batch sizes of iterations to run in stable iteration size batches
* harness-once - a simplified harness that simply runs once
* harness-perf - a simplified harness that runs for exactly the hinted number of iterations
* harness-stackprof - a harness to profile the benchmark with stackprof
* harness-stats - count method calls and loop iterations
* harness-vernier - a harness to profile the benchmark with vernier
* harness-warmup - a harness which runs as long as needed to find warmed up (peak) performance

To use it, run a benchmark script directly, specifying a harness directory with `-I`:

```
ruby -Iharness benchmarks/railsbench/benchmark.rb
```

There is also a robust but complex CI harness in [the yjit-metrics repo](https://github.com/Shopify/yjit-metrics).

### Iterations and duration

With the default harness, the number of iterations and duration
can be controlled by the following environment variables:

* `WARMUP_ITRS`: The number of warm-up iterations, ignored in the final comparison (default: 15)
* `MIN_BENCH_ITRS`: The minimum number of benchmark iterations (default: 10)
* `MIN_BENCH_TIME`: The minimum seconds for benchmark (default: 10)

You can also use `--warmup`, `--bench`, or `--once` to set these environment variables:

```sh
# same as: WARMUP_ITRS=2 MIN_BENCH_ITRS=3 MIN_BENCH_TIME=0 ./run_benchmarks.rb railsbench
./run_benchmarks.rb railsbench --warmup=2 --bench=3

# same as: WARMUP_ITRS=0 MIN_BENCH_ITRS=1 MIN_BENCH_TIME=0 ./run_benchmarks.rb railsbench
./run_benchmarks.rb railsbench --once
```

There is also a handy script for running benchmarks just once using
`WARMUP_ITRS=0 MIN_BENCH_ITRS=1 MIN_BENCH_TIME=0`, for example
with the `--yjit-stats` command-line option:

```
./run_once.sh --yjit-stats benchmarks/railsbench/benchmark.rb
```

### Using perf

There is also a harness to use Linux perf. By default, it only runs a fixed number of iterations.
If `PERF` environment variable is present, it starts the perf subcommand after warmup.

```sh
# Use `perf record` for both warmup and benchmark
perf record ruby --yjit-perf=map -Iharness-perf benchmarks/railsbench/benchmark.rb

# Use `perf record` only for benchmark
PERF=record ruby --yjit-perf=map -Iharness-perf benchmarks/railsbench/benchmark.rb
```

This is the only harness that uses `run_benchmark`'s argument, `num_itrs_hint`.

### Printing YJIT stats

The `--yjit-stats` option of `./run_benchmarks.rb` allows you to print the diff of YJIT stats counters
after each iteration with the default harness.

```
./run_benchmarks.rb --yjit-stats=code_region_size,yjit_alloc_size
```

## Measuring memory usage

`--rss` option of `run_benchmarks.rb` allows you to measure RSS (resident set size).

```
./run_benchmarks.rb --rss
```

The harness samples RSS once per iteration across the benchmarking window (after
warmup), so the `RSS (MiB)` column reports the mean working set during measurement
along with its run-to-run variability (`mean ± stddev%`), and the `RSS` ratio is
computed from those means. The raw per-iteration samples are stored in the JSON
output under `rss_samples` (bytes).

For reference, the JSON output also keeps `rss`, a single snapshot taken after a
full GC at the end of the run (the retained set, a lower bound), and `maxrss`, the
process's lifetime peak from `getrusage`.

## Measuring Ractor GC activity

The `--ractor-gc` option of `run_benchmarks.rb` collects Ractor-local GC
metrics for benchmarks that use the Ractor harness (`--category ractor`),
in both the per-worker mode and scenario mode.
The target must use Ruby 4.1 or newer with per-Ractor global GC attribution
([ruby/ruby#19147](https://github.com/ruby/ruby/pull/19147)); older targets
fail before warmup.

```sh
./run_benchmarks.rb --category ractor --chruby=base::ruby-base --ractor-gc
```

Each measured iteration samples `GC.stat` and GC total time in every worker
Ractor's own object space. The JSON output records the scope as
`gc_scope: "ractor-local-workload"`, `gc_stat_scope: "ractor-local"`, and
`gc_measure_total_time_scope: "ractor-local"`, plus the target's `gc_config`.

The text summary shows GC data in separate tables after the timing table.
A single-executable report has one `GC summary` table. A comparison report
has a `GC time ratios` table (base/comparison) and a `GC counts` table
(base → comparison). A table hides a column that has no data in any row and
lists the hidden columns below the table. A ratio column has no data when it
is `N/A` in every row; a `0.000` ratio stays visible. Any other column has no
data when it is zero or `N/A` in every row.

* Tables marked `worker sum` add the Ractor-local counters and GC times of
  the sampled workers of each iteration. `GCs/iter` is the sum of `minor/iter`,
  `major/iter`, and `global/iter`; a global cycle counts under `global` on
  the Ractor that initiated it, not under `major`. Single-executable reports
  also show `GC ms/worker`, which divides each iteration's worker-sum GC
  time by its sampled worker count, then averages.
* `compacts*` shows the main Ractor's
  `GC.stat(:compact_count)` delta. Every global compacting cycle increments
  it in every object space, so it is not summed across workers.

Worker records in the JSON output never contain the controller-observed
counter, and it is never summed across workers.

## Rendering a graph

`--graph` option of `run_benchmarks.rb` allows you to render benchmark results as a graph.

```bash
# Write a graph at data/output_XXX.png (it will print the path)
./run_benchmarks.rb --graph
```

### Installation

Before using this option, you might need to install the dependencies of [Gruff](https://github.com/topfunky/gruff):

```bash
# macOS
brew install imagemagick

# Ubuntu
sudo apt-get install libmagickwand-dev
```

### Changing font size

You can regenerate a graph with `misc/graph.rb`, changing its font size.

```
Usage: misc/graph.rb [options] CSV_PATH
        --title SIZE                 title font size
        --legend SIZE                legend font size
        --marker SIZE                marker font size
```

## Disabling CPU Frequency Scaling

To disable CPU frequency scaling with an Intel CPU, edit `/etc/default/grub` or `/etc/default/grub.d/50-cloudimg-settings.cfg` and add `intel_pstate=no_hwp` to `GRUB_CMDLINE_LINUX_DEFAULT`. It’s a space-separated list.

Then:
```bash
sudo update-grub
sudo reboot
sudo sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo'
```

To verify things worked:
 - `cat /proc/cmdline` to see the `intel_pstate=no_hwp` parameter is in there
 - `ls /sys/devices/system/cpu/intel_pstate/` and `hwp_dynamic_boost` should not exist
 - `cat /sys/devices/system/cpu/intel_pstate/no_turbo` should say `1`

Helpful docs:
 - https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/processor_state_control.html#baseline-perf
