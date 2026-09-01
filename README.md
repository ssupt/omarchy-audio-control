# Advanced Audio Control for Omarchy

Advanced Audio Control expands Omarchy Quattro's built-in audio widget with
controls for routing applications and configuring PipeWire audio devices.

It follows Omarchy's visual language and preserves the familiar quick controls
instead of introducing a separate mixer application.

## Features

- Remember each application's chosen output across stream and application restarts.
- Route recording applications to a preferred microphone and control their gain.
- Show application icons and live playback/recording activity meters.
- Optionally extend output volume to 150% and adjust stereo channel balance.
- Select endpoint ports when a live device exposes multiple usable paths.
- Configure device profiles and Bluetooth codecs in separate keyboard-navigable tabs.
- Control when Bluetooth headsets switch into communication mode.
- Choose whether automatic Bluetooth profile selection favors quality or latency.
- Configure supported WirePlumber safety policies, including mono audio, pause on
  output loss, disconnect protection, and HDMI channel detection.
- Set safe starting volumes for new devices and playback or recording applications.
- Keep microphone use visible on the bar, including the recording applications and
  a persistent app-count badge even while the microphone is muted.
- Optionally notify when a new application starts capturing, while respecting
  Omarchy's Do Not Disturb setting and suppressing shell-startup noise.
- Show live microphone peak hold and a latched clipping warning in the quick mixer
  and recording badge.
- Record a private five-second microphone test, then explicitly play it back or
  discard it; the temporary clip is removed when the Audio window closes.
- Save the whole setup as an audio scene and restore it with one click from the
  quick mixer: defaults, device volumes and balance, ports, and card profiles.
  Scenes never restore output mutes and never power cards off; devices that are
  absent are skipped and reported.
- Pin any application to a device with offline routing rules that are enforced
  whenever the application starts and the device is present.
- Create named output groups that play through two to eight connected outputs
  at once, then use them as defaults or per-application destinations.
- Rename devices with aliases, mark favorites so they sort first, and hide
  devices everywhere.
- Inspect PipeWire and WirePlumber health from a Diagnostics tab: graph rate,
  quantum-derived scheduling latency, DSP load, XRUN/error counters, service
  state, negotiated device formats and channel maps, and active routes through
  filters to hardware.
- Identify every reported speaker channel at a conservative level, copy a
  privacy-conscious support report, and launch Omarchy's official audio
  recovery behind an explicit confirmation.

The bar audio icon uses left-click for the quick mixer, middle-click to mute or
unmute the microphone, right-click to mute or unmute all audio, and the wheel to
adjust output volume. Hovering it lists applications with active microphone access.

`Super+Ctrl+A` opens the same quick mixer as Omarchy's built-in audio widget.
Use the gear in that pullout—or **Setup > Audio**—for the advanced window.

The optional [Advanced Bluetooth Audio](https://github.com/ssupt/omarchy-bluetooth-audio)
companion brings the same codec controls into Omarchy's Bluetooth panel while
preserving its native pairing, discovery, and connection behavior. When both
plugins are enabled, codec and preferred-device choices are shared immediately
through `~/.config/omarchy/audio-preferences.json`.

More plugins by `ssupt`: [omarchy-plugins](https://github.com/ssupt/omarchy-plugins).

## Requirements

- Omarchy Quattro
- PipeWire with WirePlumber (`pactl`, `wpctl`, `pw-metadata`, `pw-dump`,
  `pw-top`, `pw-record`, and `pw-play`)
- ALSA utilities (`speaker-test`) and systemd user services (`systemctl`)
- `notify-send` for optional capture-start notifications
- `jq`, `hyprctl`, `timeout`, `flock`, and `wl-copy`

These commands are present in a standard Omarchy installation. Routine controls
do not require `sudo`, and the plugin does not install a background service.
Omarchy recovery may request authorization only when it needs to reset a stuck
USB audio device.

Application routes use WirePlumber's native stream-target restoration. Choosing
**Follow default output** removes the remembered target; choosing **Always use**
an output restores that choice whenever the application creates a new stream.
Recording routes follow the same behavior for microphones. Explicitly routed
recording applications stay pinned when the default input changes.

The Policy tab discovers settings from the installed WirePlumber version, so it
only shows controls the system supports. Changes use WirePlumber's persistent
settings API. Starting-volume percentages are converted to its cubic storage
scale before they are saved, keeping the displayed values perceptually accurate.

Capture-start notifications can be disabled under **Policy > Microphone privacy**.
Normal notification urgency lets Omarchy's notification service honor Do Not
Disturb. The microphone test records only after an explicit action, stores its
clip with private permissions in the user's runtime directory, never plays it
automatically, and deletes it on discard or when the Audio window closes. Stopping
before five seconds keeps the audio recorded so far and makes it ready to play.

Scenes live in `~/.config/omarchy/audio-scenes.json` and routing rules and device
preferences in `~/.config/omarchy/audio-rules.json`; both are plugin-owned and
edited through the **Scenes** and **Routing** tabs. Manual route changes on a
pinned application update its rule, and choosing follow-default deletes it.
Hidden devices disappear from the mixer until shown again in the Routing tab.

Output groups are configured under **Routing > Output groups**. A live group
behaves like one regular output throughout the plugin, so it can be selected as
the default, used by a running stream or saved as an offline application rule.
The quick mixer marks these destinations as **GROUP**. If a member disconnects,
the definition stays saved and the Routing tab names the missing output. If the
group was selected, following applications move to the first surviving member
before the broken virtual output disappears from the mixer. The group is
restored automatically when every member is available again. Each group card
also exposes member-level sliders; these change the physical device volumes, so
the same levels apply when those devices are used outside the group.
The plugin creates PipeWire's
[`module-combine-sink`](https://docs.pipewire.org/page_pulse_module_combine_sink.html)
only while the group exists and reconciles its own marked modules without a
background service. Updating or deleting a group first requires moving the
default and active applications away from it. Outputs driven by separate clocks,
especially Bluetooth devices, can drift slightly; this is a limitation of
combining independent hardware rather than a UI synchronization issue.

The Diagnostics tab refreshes only while it is visible. Its support report
contains versions, health counters, human-readable device formats, service
states, and active route labels; it excludes logs, usernames, hostnames,
configuration files, and internal device names. The speaker test performs one
finite channel-identification pass on the current default output and can be
stopped immediately. Recovery never runs silently: after confirmation it opens
`omarchy-restart-audio` in Omarchy's visible presentation terminal so USB-reset
messages or authorization requests cannot be hidden by the shell.

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

The two entry points own presentation and keyboard navigation. Shared behavior
stays outside them: `Model.js` contains pure, Node-tested transformations;
`AudioRuntime.qml` owns paths; focused controllers own policy, saved-rule,
scene, microphone-test, and diagnostics lifecycles; and `scripts/` contains
the guarded system interactions. Diagnostics remain read-only until a user
chooses a finite speaker test or confirms the official Omarchy recovery.

Advanced Audio Control is derived from Omarchy's built-in audio widget and is
distributed under the same MIT license.

## License

MIT
