# SpeakerSync

macOS menu bar app that plays system audio through the built-in speakers and a
Bluetooth output (or any combination of HAL output devices) simultaneously, by
programmatically creating a CoreAudio **stacked aggregate device** — the same
thing Audio MIDI Setup builds when you click "Create Multi-Output Device".

## Why this works for Bluetooth but not AirPlay

Bluetooth A2DP sinks are standard CoreAudio HAL devices (transport type
`kAudioDeviceTransportTypeBluetooth`), so they can be sub-devices of an
aggregate. AirPlay endpoints are routed through a private path outside the HAL
and cannot be combined this way — which is why the earlier
AudioRouterPro/Sonos attempt needed a RAOP sender instead.

The key detail vs. a plain aggregate: `kAudioAggregateDeviceIsStackedKey = 1`
makes the aggregate *multi-output* (every sub-device receives the same mixed
signal) instead of concatenating channels across sub-devices.

## Build & run

```sh
cd SpeakerSync
swift run              # quick run from terminal
./make-app.sh          # or build dist/SpeakerSync.app (LSUIElement bundle)
```

No external dependencies; AppKit + CoreAudio only. Requires macOS 13+.

## Usage

- Click the speaker icon in the menu bar.
- **Combined Output: On/Off** — creates/destroys the aggregate and swaps the
  system default output. On disable (or quit), the previous default output is
  restored and the aggregate is destroyed (`AudioHardwareDestroyAggregateDevice`).
- The device list shows every HAL output device with a checkmark for the ones
  included. Until you touch the list, selection is **automatic**: built-in
  speakers + every connected Bluetooth output, re-evaluated whenever devices
  come and go (`kAudioHardwarePropertyDevices` listener). Once you toggle a
  device manually, your selection is persisted and used as-is.
- If a selected device disconnects while active, the aggregate is rebuilt with
  the remaining devices; if all vanish, the previous default is restored.
- Changing the output in System Settings while active is treated as an
  external "off": the aggregate is torn down and your choice is respected.

## Behavior details

- Clock master: the built-in (wired) device keeps its native clock
  (`kAudioAggregateDeviceMainSubDeviceKey`); all other sub-devices get
  `kAudioSubDeviceDriftCompensationKey = 1` so the HAL resamples them to
  follow it. Drift compensation is also re-applied post-creation on the live
  sub-device objects since some macOS builds ignore the composition-dict key.
- The aggregate is public (`kAudioAggregateDeviceIsPrivateKey = 0`), so it is
  visible in Audio MIDI Setup while active.

## Known macOS limitations (same as Audio MIDI Setup's Multi-Output Device)

- **Volume keys don't work** while a multi-output device is the default —
  aggregates have no master volume. Set per-device volume beforehand, or in
  Audio MIDI Setup.
- **Bluetooth codec latency is not corrected.** Drift compensation fixes
  clock *rate* differences, not the fixed ~100–250 ms buffering delay of
  Bluetooth audio. With both outputs audible in the same room you will hear
  the Bluetooth device lag slightly behind the speakers. There is no HAL API
  to fully remove this; `kAudioSubDeviceExtraInputLatencyKey`-style offsets
  could partially compensate but the true BT latency varies by codec and
  device.
