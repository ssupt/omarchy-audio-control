# Development and release

Builds require Rust/Cargo **1.85 or newer**, libclang, pkg-config, and PipeWire
and libpulse headers. Build a candidate outside the live plugin directory:

```bash
./test/all
python3 packaging/build-release.py --output /tmp/omarchy-audio-release
python3 packaging/build-release.py --check /tmp/omarchy-audio-release
omarchy-plugin-validate /tmp/omarchy-audio-release
```

The `scripts/audio-rust-backend` installer and `packaging/systemd` units support
testing socket activation outside the plugin lifecycle. `install` builds or
accepts a release binary, replaces the user units, and restarts the service;
`uninstall` removes that installation. A normal plugin install manages its own
service lifecycle.

The release builder records a source identity for the Rust binary and QML
runtime. Keep packaged sources and binaries together when validating or
publishing a candidate.

See [Bluetooth integration](INTEGRATION.md) for the shared storage and default
switching contract and [performance](PERFORMANCE.md) for measured results.
