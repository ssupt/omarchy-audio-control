# Advanced Audio Control for Omarchy

An audio mixer for Omarchy with device settings, application routing, output
groups, microphone tests and saved setups. It replaces the built-in audio widget
and uses Omarchy's bar, shortcuts and theme. A Rust service coordinates
PipeWire and WirePlumber; the interface uses Quickshell/QML.

## Screenshots

<table>
  <tr><th>Quick mixer</th><th>Advanced panel</th></tr>
  <tr>
    <td valign="top"><a href="screenshot-mixer.png"><img src="screenshot-mixer.png" width="348" alt="Quick mixer with device, microphone and application volume controls"></a></td>
    <td valign="top"><a href="screenshot-advanced.png"><img src="screenshot-advanced.png" width="684" alt="Advanced panel with device profiles, balance, microphone test and settings tabs"></a></td>
  </tr>
</table>

## Features

- Device and application volume, mute, stereo balance and live meters. Output
  volume stops at 100%, or 150% with boost enabled.
- Device profiles, ports and supported Bluetooth codecs and communication modes.
- Persistent application routing, device aliases, favorites and visibility settings.
- Groups of two to eight outputs, with individual device volume controls.
- Saved scenes for defaults, volume, balance, ports and profiles.
- Microphone activity indicators, optional capture notifications and a five-second
  record-and-playback test.
- WirePlumber policies, diagnostics, speaker identification and audio recovery.

Group members with separate clocks, especially Bluetooth devices, may drift.
Microphone tests start only on request. Clips stay in memory and are removed
when discarded or when the advanced panel closes.

## Controls

| Action | Control |
| --- | --- |
| Open mixer | Left-click the audio icon or press `Super+Ctrl+A` |
| Change output volume | Scroll over the audio icon |
| Mute microphone | Middle-click the audio icon |
| Mute all audio | Right-click the audio icon |
| See microphone users | Hover over the audio icon |
| Open advanced panel | Select the mixer gear |

For applications, **Follow default output** clears a saved destination;
**Always use** keeps the chosen device across restarts. Recording applications
can also stay pinned to a microphone.

## Install

Requires **Omarchy Quattro on x86_64 Linux**, PipeWire and WirePlumber, with
Omarchy's usual audio and desktop tools. You need no Rust toolchain to install it.

Install the published version:

```bash
omarchy plugin add https://github.com/ssupt/omarchy-audio-control.git --enable
```

Update or remove it:

```bash
omarchy plugin update ssupt.audio-control
omarchy plugin remove ssupt.audio-control
```

Disabling or removing the plugin restores Omarchy's built-in audio widget.

To add **Setup > Audio** to the menu, run:

```bash
~/.config/omarchy/plugins/ssupt.audio-control/scripts/audio-menu-entry install
```

Use the same helper with `remove` before removing the plugin.

## Settings

Existing files and schemas are preserved under `~/.config/omarchy` (or
`$XDG_CONFIG_HOME/omarchy`).

| File | Contents |
| --- | --- |
| `audio-control.json` | Output boost and capture notifications |
| `audio-preferences.json` | Preferred devices and Bluetooth profiles |
| `audio-rules.json` | Application rules, device preferences and output groups |
| `audio-scenes.json` | Saved scenes |

The optional [Advanced Bluetooth Audio](https://github.com/ssupt/omarchy-bluetooth-audio)
companion shares `audio-preferences.json`.
This Rust branch also accepts the companion panel's node ID and name through
`audio-output-set-default` and `audio-input-set-default`. The service checks
that the live endpoint still matches before applying the default change. The
compatibility helpers and the Bluetooth service branch should be released
together.

## Development

Builds require Rust/Cargo **1.85 or newer**, libclang, pkg-config, and PipeWire
and libpulse headers. Build a candidate outside the live plugin directory:

```bash
./test/all
python3 packaging/build-release.py --output /tmp/omarchy-audio-release
python3 packaging/build-release.py --check /tmp/omarchy-audio-release
omarchy-plugin-validate /tmp/omarchy-audio-release
```

[MIT license](LICENSE), matching Omarchy's original audio widget.
More plugins: [omarchy-plugins](https://github.com/ssupt/omarchy-plugins).
