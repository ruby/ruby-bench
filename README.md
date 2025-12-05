ruby-bench
==========

Small set of benchmarks and scripts for the Ruby programming language.

The benchmarks are found in the `benchmarks` directory. Individual Ruby files
in `benchmarks` are microbenchmarks. Subdirectories under `benchmarks` are
larger macrobenchmarks. Each benchmark relies on a harness found in
[./harness/default.rb](harness/default.rb). The harness controls the number of times a benchmark is
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

```bash
ruby benchmarks/fib.rb
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
  directory. The `ractor` harness is used for both types of benchmark.

* **`--category ractor-only`** - Runs ONLY benchmarks from the
  `benchmarks-ractor` directory, ignoring regular benchmarks even if they are
  marked with `ractor: true`. This category also automatically uses the
  `ractor` harness.

### Directory Structure

The `benchmarks-ractor/` directory sits at the same level as the main
`benchmarks` directory, and contains Ractor-specific benchmark
implementations that are designed to test Ractor functionality. They are not
intended to be used with any harness except `ractor`.

### Usage Examples

```bash
# Run all Ractor-capable benchmarks (both regular and Ractor-specific)
./run_benchmarks.rb --category ractor

# Run only dedicated Ractor benchmarks from benchmarks-ractor directory
./run_benchmarks.rb --category ractor-only
```

Note: The `ractor` harness is automatically selected when using these
categories, so there's no need to specify `--harness` manually.

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

You can find several test harnesses in the `harness/` directory:

* `default` - the normal default harness, with duration controlled by warmup iterations and time/count limits
* `bips` - a harness that measures iterations/second until stable
* `continuous` - a harness that adjusts the batch sizes of iterations to run in stable iteration size batches
* `once` - a simplified harness that simply runs once
* `perf` - a simplified harness that runs for exactly the hinted number of iterations
* `stackprof` - a harness to profile the benchmark with stackprof
* `stats` - count method calls and loop iterations
* `vernier` - a harness to profile the benchmark with vernier
* `warmup` - a harness which runs as long as needed to find warmed up (peak) performance
* `chain` - a harness to chain multiple harnesses together
* `mplr` - a harness for multiple iterations with time limits

### Selecting a harness

**Using the `HARNESS` environment variable**

```bash
# Run with specific harness
HARNESS=perf ruby benchmarks/fib.rb
HARNESS=stackprof ruby benchmarks/railsbench/benchmark.rb
HARNESS=vernier ruby benchmarks/optcarrot/benchmark.rb

# Combine with Ruby options
HARNESS=perf ruby --yjit benchmarks/fib.rb
HARNESS=once ruby --yjit-stats benchmarks/railsbench/benchmark.rb
```

**Alternative: Use `run_once.rb` with `--harness` option**:

```bash
./run_once.rb --harness=perf benchmarks/railsbench/benchmark.rb
./run_once.rb --harness=stackprof benchmarks/fib.rb

# With Ruby options (use -- separator)
./run_once.rb -- --yjit benchmarks/railsbench/benchmark.rb
./run_once.rb --harness=perf -- --yjit-stats benchmarks/fib.rb
```

When using `run_benchmarks.rb`, you can specify a harness with the `--harness` option:

```bash
./run_benchmarks.rb --harness=once
./run_benchmarks.rb --harness=perf
```

There is also a robust but complex CI harness in [the yjit-metrics repo](https://github.com/Shopify/yjit-metrics).

### Chain harness

The `chain` harness allows you to combine multiple harnesses together. This is useful when you want to run a benchmark through multiple analysis tools or measurement approaches in sequence.

Use the `HARNESS_CHAIN` environment variable to specify which harnesses to chain (comma-separated, at least 2 required):

```bash
# Chain the 'once' and 'default' harnesses (runs benchmark once, then with default iterations)
HARNESS=chain HARNESS_CHAIN="once,default" ruby benchmarks/fib.rb

# Profile with vernier while using ractor harness
HARNESS=chain HARNESS_CHAIN="vernier,ractor" ruby benchmarks-ractor/some_benchmark.rb

# Using run_once.rb
HARNESS_CHAIN="once,default" ./run_once.rb --harness=chain benchmarks/fib.rb
```

The harnesses are executed in the order specified, with each harness wrapping the previous one.

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

You can also run a single benchmark directly with Ruby:

```bash
# Run once with YJIT stats
ruby --yjit-stats benchmarks/railsbench/benchmark.rb

# Or use run_once.rb script
./run_once.rb -- --yjit-stats benchmarks/railsbench/benchmark.rb
```

### Using perf

There is also a harness to use Linux perf. By default, it only runs a fixed number of iterations.
If `PERF` environment variable is present, it starts the perf subcommand after warmup.

```bash
# Use `perf record` for both warmup and benchmark
HARNESS=perf perf record ruby --yjit-perf=map benchmarks/railsbench/benchmark.rb

# Use `perf record` only for benchmark
HARNESS=perf PERF=record ruby --yjit-perf=map benchmarks/railsbench/benchmark.rb

This is the only harness that uses `run_benchmark`'s argument, `num_itrs_hint`.

### Printing YJIT stats

The `--yjit-stats` option of `./run_benchmarks.rb` allows you to print the diff of YJIT stats counters
after each iteration with the default harness.

```
./run_benchmarks.rb --yjit-stats=code_region_size,yjit_alloc_size
```

## Measuring memory usage

`--rss` option of `run_benchmarks.rb` allows you to measure RSS after benchmark iterations.

```
./run_benchmarks.rb --rss
```

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
