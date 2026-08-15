# Advanced Audio Control for Omarchy

Advanced Audio Control expands Omarchy Quattro's built-in audio widget with
controls for routing applications and configuring PipeWire audio devices.

It follows Omarchy's visual language and preserves the familiar quick controls
instead of introducing a separate mixer application.

## Features

- Remember each application's chosen output across stream and application restarts.
- Configure device profiles and Bluetooth codecs in separate keyboard-navigable tabs.
- Control when Bluetooth headsets switch into communication mode.

The optional [Advanced Bluetooth Audio](https://github.com/ssupt/omarchy-bluetooth-audio)
companion brings the same codec controls into Omarchy's Bluetooth panel while
preserving its native pairing, discovery, and connection behavior.

More plugins by `ssupt`: [omarchy-plugins](https://github.com/ssupt/omarchy-plugins).

## Requirements

- Omarchy Quattro
- PipeWire with WirePlumber (`pactl`, `wpctl`, and `pw-metadata`)
- `jq`, `hyprctl`, and `timeout`

These commands are present in a standard Omarchy installation. The plugin does
not require `sudo` or install a background service.

Application routes use WirePlumber's native stream-target restoration. Choosing
**Follow default output** removes the remembered target; choosing **Always use**
an output restores that choice whenever the application creates a new stream.

## Installation

```bash
omarchy plugin add https://github.com/ssupt/omarchy-audio-control.git --enable
~/.config/omarchy/plugins/ssupt.audio-control/scripts/audio-menu-entry install
```

The plugin replaces the built-in audio widget while it is enabled. Removing or
disabling it restores Omarchy's original widget. The second command adds the
optional **Setup > Audio** menu entry through Omarchy's user-menu extension.

To add codec selection directly to the Bluetooth panel too:

```bash
omarchy plugin add https://github.com/ssupt/omarchy-bluetooth-audio.git --enable
```

## Updating

```bash
omarchy plugin update ssupt.audio-control
```

## Removing

```bash
~/.config/omarchy/plugins/ssupt.audio-control/scripts/audio-menu-entry remove
omarchy plugin remove ssupt.audio-control
```

Plugins run as unsandboxed code inside `omarchy-shell`. Review third-party
plugin code before enabling it.

## Development

```bash
./test/all
omarchy-plugin-validate .
```

Advanced Audio Control is derived from Omarchy's built-in audio widget and is
distributed under the same MIT license.

## License

MIT
