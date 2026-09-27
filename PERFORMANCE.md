# Audio service performance observations — 23 September 2026

This benchmark compared release 0.8.1 at
[`71c0b6a695b6aa10c66d550e462c79919eebdf2d`](https://github.com/ssupt/omarchy-audio-control/commit/71c0b6a695b6aa10c66d550e462c79919eebdf2d)
with a packaged `0.9.0-dev.27` Rust build at
[`b5d2c041d14a9a6ad98f9cff229dbe7de02a1eee`](https://github.com/ssupt/omarchy-audio-control/commit/b5d2c041d14a9a6ad98f9cff229dbe7de02a1eee).
The Rust build ID was
`354ed9ac2bbed2dda2698c2fff1098a937fd87f3f4a2643340a8fe7d3ab95461`.
The test host has a 13th Gen Intel Core i7-13700HX CPU (24 logical CPUs).
These numbers are observations, not a CI threshold or a promise for other
hardware. The [raw measurements](benchmark-2026-09-23.json) include the
individual runs and volume observations.

| Measurement | 0.8.1 | Rust candidate |
| --- | ---: | ---: |
| CPU with advanced window open, percent of one core | 3.225–3.260% | 0.015–0.016% |
| Helper launches during each open window | 13 | 0 |
| CPU after closing the window | 0.493–0.538% | 0.010–0.013% |
| Median proportional set size, window open | 75.08 MiB | 77.79 MiB |
| Median observed volume-command completion | 1 ms | 1 ms |

The benchmark used a private dummy PipeWire/Pulse/WirePlumber graph and a
headless Weston compositor. It loaded each version's real Quickshell UI, ran
two rounds in alternating order, and observed each scenario for 10 seconds.
CPU counts the Quickshell widget, relay, service, and exited helpers in one
cgroup; proportional set size sums the live processes. Each run included 20
volume changes. An independent PipeWire observer timed from UI dispatch until
it saw the requested server property. The clock had 1 ms resolution.

The candidate used less CPU while the advanced window was open and launched no
recurring helpers in those windows. It used about 2.7 MiB more memory there.
Both versions had the same median observed volume response at this resolution.
The test did not measure acoustic latency, codec negotiation, or physical audio
hardware. Reproduce the benchmark with `test/integration/benchmark.py` and a
supported Omarchy shell, Weston, and private audio graph.
