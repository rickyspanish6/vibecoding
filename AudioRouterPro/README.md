# AudioRouter Pro

A macOS menu bar app that plays your Mac's audio through **local outputs and AirPlay speakers simultaneously, in sync** — the Airfoil architecture: capture the system audio stream, then fan it out ourselves. The app speaks the AirPlay audio protocol (RAOP) directly to receivers over the network, so every speaker Control Center can see is reachable instantly, with zero Control Center involvement and no CoreAudio AirPlay routing at all.

- macOS 14.4+ (Core Audio process taps), SwiftUI `MenuBarExtra`
- Pure Swift: CoreAudio + AVFoundation + Network/Bonjour + CryptoKit. No C dependencies, no kext, no driver.
- Distribution target: Developer ID (hardened runtime on, App Sandbox off)

## Architecture

```
System audio ──▶ Core Audio Process Tap ──▶ Ring buffer ──┬──▶ Local leg: AVAudioEngine → selected output device
                (global, mute-when-tapped)  (30 s, shared) │     (delayed by the AirPlay latency = in sync)
                                                           └──▶ AirPlay leg(s): RAOPSender per receiver
                                                                 RTSP + RTP/UDP L16 → Bonjour-resolved address
```

**Capture** ([CaptureEngine.swift](AudioRouterPro/CaptureEngine.swift)): a global process tap (`CATapDescription` + `AudioHardwareCreateProcessTap`, macOS 14.4+) captures the mixed output of every process. The tap uses `muteBehavior = .muted`, which silences the tapped audio at the physical device — **the app's legs become the only audible path, so double-audio is impossible by construction** (no silent-output-device tricks needed). The tap is wrapped in a private aggregate device whose IOProc writes float32 stereo into a shared ring buffer. The aggregate is asked to run at 44.1 kHz so the AirPlay leg usually needs no resampling (a linear resampler covers the fallback). Destroying the tap (toggle off / quit) un-mutes normal playback.

**Local leg** (same file): an `AVAudioSourceNode` renders the ring through any output device ("Play computer audio through", Airfoil's model). It reads `delay` seconds behind the capture head — set automatically to the slowest AirPlay leg's negotiated latency plus the feeder backlog, which is what keeps the room in sync. Delay changes never replay audio: growing the delay holds the cursor and plays silence until real time catches up; shrinking jumps forward. A ±500 ms **Sync trim** slider under Advanced fine-tunes against receivers that add their own DSP latency.

**AirPlay leg** ([RAOPSender.swift](AudioRouterPro/RAOPSender.swift)): a clean-room Swift implementation of classic RAOP v2, ported from the protocol as implemented by `philippe44/libraop` (evaluated for vendoring first, per plan — it works, but ships no LICENSE file, so the wire protocol was reimplemented instead; its prebuilt `cliraop` was used as a behavioral reference and first proof against real hardware). Each active receiver gets its own `RAOPSender` + feeder thread reading the shared ring, so multi-receiver fan-out is structural — the UI simply allows toggling several on.

The sender implements:
- RTSP over TCP: `POST /auth-setup` (Curve25519, expected by AirPlay-2-compat receivers), `ANNOUNCE` (SDP `L16/44100/2`), `SETUP` (control + timing ports), `RECORD` (returns `Audio-Latency`), `SET_PARAMETER` volume (-30…0 dB, -144 mute), `FLUSH`/`TEARDOWN`, periodic `OPTIONS` keepalive.
- RTP audio over UDP: 352 frames/packet, big-endian L16, marker bit on the first packet.
- Sync channel: 20-byte `0xd4` packets (~1/s) mapping the RTP timestamp axis onto NTP.
- Timing channel: answers the receiver's NTP queries (`0x52`→`0xd3`). Replies go to the **source address of the query** — receivers probe this port *during* `SETUP` and won't complete the handshake until answered (the one non-obvious protocol detail; everything else fails loud, this fails silent).
- Retransmit: a 512-packet backlog serves `0x55` resend requests wrapped in `0xd6` headers.

**Discovery** ([AirPlayDiscovery.swift](AudioRouterPro/AirPlayDiscovery.swift)): Bonjour `_raop._tcp` browse + resolve gives every receiver's name (instance names are `<MAC>@<name>`), IPv4, RTSP port, and TXT record. The `et` key (encryption types) tiers compatibility.

## Receiver compatibility tiers

| Tier | Devices | Status |
|---|---|---|
| **Classic RAOP, no encryption** (`et` contains `0`) | Sonos One/Port-class AirPlay 2 speakers, AirPort Express (newer fw), many third parties | ✅ Supported now — verified live against a Sonos One ("One", latency 1250 ms) |
| **RSA-encrypted classic RAOP** (`et=1`, no `0`) | Original AirPort Express | ❌ Badged unsupported (needs legacy RSA/AES payload encryption) |
| **AirPlay 2 auth required** | HomePod, Apple TV, Macs | ❌ Badged "Requires AirPlay 2 auth — not yet supported". Needs HAP transient pairing (SRP/ed25519) — the hard part Airfoil solved over years; explicit follow-up milestone. |

## Permissions

Two TCC prompts, both surfaced in the menu UI:

1. **Local Network** (first launch) — Bonjour discovery of receivers.
2. **System Audio Recording** (first time "Route system audio" is enabled) — the process tap. If denied, the menu shows a banner with a button to System Settings → Privacy & Security → Screen & System Audio Recording. The header's green level meter is live proof that samples are flowing once granted.

## Using it

1. Click the speaker icon → toggle **Route system audio**. Grant the capture permission. Audio now plays through the device under "Play computer audio through" (pick any local output); the level meter moves with your music.
2. Check **Transmit** next to any supported speaker. The app resolves it via Bonjour, handshakes RAOP directly, and ~1.3 s later (the negotiated receiver latency) both outputs play **in sync** — the local leg is automatically delayed to match.
3. Per-receiver volume sliders appear under active speakers; the master slider scales everything.
4. Toggle routing off or quit → tap destroyed, normal macOS playback resumes instantly.

## Test plan / verification status

1. **Tap captures system audio** — grant the prompt, play music, watch the header level meter. *(Needs a human click for TCC; meter is the proof.)*
2. **Local leg, no double audio** — with routing on and speakers selected as local output, exactly one playback path should be audible (the tap mutes the OS path by design). Toggle routing off → playback continues via macOS normally.
3. **RAOP leg, zero Control Center** — ✅ verified from CLI against Sonos "One" (10.0.0.62:7000): full handshake, 626 RTP packets / 5 s tone, clean teardown. In-app: check Transmit on "One" or "Port".
4. **Sync within tolerance** — play rhythmic music to speakers + one Sonos; the beats should align (< ~50 ms). If a receiver adds its own delay, trim with Advanced → Sync.
5. Kill a speaker mid-stream → its leg fails/badges without affecting the local leg; re-toggle to reconnect.

## What was removed in the pivot

The previous architecture (multi-output aggregate device + drift compensation + system default-output switching) is gone — git has it. It could only reach AirPlay receivers that macOS had already connected via Control Center, because the HAL exposes no AirPlay presence when idle and there is no public API to open a route. The only kept pieces: the HAL device helpers, transport model, Bonjour plumbing, and the menu bar shell.

## Building

```sh
./build.sh
```

Builds Release, ad-hoc signs, and (re)launches. Build products go to `~/Library/Developer/AudioRouterPro-build` (not `./build`) because this folder is iCloud-synced and the file provider's xattrs break codesign. Or open `AudioRouterPro.xcodeproj` in Xcode 15+. No dependencies.

## Project layout

```
AudioRouterPro/
├── AudioRouterPro.xcodeproj
├── AudioRouterPro/
│   ├── AudioRouterProApp.swift   # @main, MenuBarExtra, terminate hook
│   ├── StreamEngine.swift        # Coordinator: capture + legs + sync + volumes
│   ├── CaptureEngine.swift       # RingBuffer, process-tap capture, local leg
│   ├── RAOPSender.swift          # Classic RAOP v2: RTSP/RTP/sync/timing
│   ├── AirPlayDiscovery.swift    # Bonjour browse + resolve (_raop._tcp, TXT)
│   ├── AudioDevice.swift         # HAL wrappers + device model
│   ├── MenuBarView.swift         # Airfoil-style UI: local picker, Transmit rows
│   ├── Info.plist                # LSUIElement, Bonjour + audio-capture usage
│   └── AudioRouterPro.entitlements
├── build.sh
└── README.md
```

## Follow-up milestones (not in v1)

- **AirPlay 2 HAP auth** (HomePod / Apple TV): SRP transient pairing, ed25519 verify, ChaCha20-Poly1305 — unlocks the remaining receiver tier.
- RSA/AES legacy encryption for first-gen AirPort Express.
- ALAC encoding (AudioToolbox has an encoder built in; L16 is fine for LAN bandwidth but ALAC halves it).
- Per-app capture (tap a specific process instead of the global mix) — Airfoil's source picker.
- Speaker groups, auto-transmit on launch, silence monitor (Airfoil parity features).
