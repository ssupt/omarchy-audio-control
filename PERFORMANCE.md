# Audio service performance observations — 23 September 2026

This benchmark compared release 0.8.1 with a packaged `0.9.0-dev.27` Rust
build on one machine. These numbers are observations, not a CI threshold or a
promise for other hardware. The [raw measurements](benchmark-2026-09-23.json)
include the individual runs and volume observations.

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
