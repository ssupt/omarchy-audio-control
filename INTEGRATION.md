# Bluetooth companion integration

[Advanced Bluetooth Audio](https://github.com/ssupt/omarchy-bluetooth-audio)
shares `audio-preferences.json` with this plugin for preferred devices and audio
profiles. Supported existing schemas are preserved. Coordinate releases of the
two service branches when changing their shared contract.

The audio service accepts the companion's node ID and name through
`default.compat`. Before changing a default output or input, it confirms that
the live endpoint still matches those values. The companion waits for the
service result and live default state before reporting success. Compatibility
helpers remain available to older companion releases.

The service watches configuration files through the current target of a safe
`~/.config/omarchy` directory symlink. After retargeting that symlink, restart
the audio service so its watches attach to the new target. An explicit store
read may see the new files sooner, but does not move the watches.
