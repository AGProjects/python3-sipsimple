# AG Podcast Mixer link

How AG CuteMusic's mixer and Blink exchange audio and call data: the mixer's mix is Blink's microphone in a call,
what the call plays is the mixer's BLINK strip, and each side knows what the other is doing (what plays, who is in
the call).

Two designs are described here: **v1**, the shared-memory ring link that works today on Linux and macOS, and **v2**,
the design that replaces it: a real audio device for Blink's microphone, other programs' sound captured without a
device, and the data exchanged through the device (macOS) or D-Bus (Linux). v2 is decided; v1 stays until v2 works
end to end, then goes (see Removed in v2).

Device name in both: **AG Podcast Mixer**. Audio: 48 kHz, stereo. A headset is required: Blink's echo cancelling is
off while AG Podcast Mixer is the input device.


## v1: the ring link (today)

### Audio

AG CuteMusic and Blink exchange 48 kHz stereo s16le PCM through two shared-memory rings in a per-user directory:
`$AGPM_DIR`, else `$XDG_RUNTIME_DIR/ag-podcast-mixer` (Linux), `$TMPDIR/ag-podcast-mixer` (macOS).

| File | Writer | Reader | Content |
|---|---|---|---|
| `to-call.ring` | AG CuteMusic | Blink | the mix: the mic, and the music while TO CALLS is on |
| `from-call.ring` | Blink | AG CuteMusic | what the call plays: the BLINK strip |
| `mixer.lock` | AG CuteMusic (flock) | Blink | the mixer runs: the device is listed |
| `blink.lock` | Blink (flock) | AG CuteMusic | Blink runs: the BLINK strip is shown |
| `calls.json` | Blink | AG CuteMusic | the calls and rooms in progress |
| `show-mixer.request` | Blink | AG CuteMusic | Blink's notice icon: show the mixer (deleted when read) |

Ring: a 64-byte header (`agpm.h`, `pjmedia_agpm_ring_header`: magic "AGPM", version 1, channels, rate, capacity
in frames (a power of two), writer pid, writer generation, write index, read index), then capacity frames of
2 x s16le. One writer, one reader; the writer never waits (drops what does not fit), the reader resyncs when the
writer restarts (generation) or falls a whole ring behind. Writer quantum 5 ms (240 frames); capacity 4096 frames
(85 ms).

`calls.json`: `{"calls": [...]}`, each `{"kind": "call", "name", "address", "held"}` or
`{"kind": "room", "name", "participants": [names]}`.

### Code

- SDK: `deps/patches/2.17/63_agpm_audio_device.patch` (pjmedia-audiodev `agpm.h`, `agpm_dev.c`): an audio device
  factory with the one device, 2 in / 2 out, listed while `mixer.lock` is held and both rings are valid; its own
  pjmedia clock, a WSOLA delay buffer on the capture for the drift against AG CuteMusic's clock, conversion to the
  stream's rate and channels. Engine: `podcast_mixer_available`, `podcast_mixer_dir`.
- `tools/agpm.py`: the Python ends (canonical copy; AG CuteMusic and Blink Qt carry copies). `tools/agpm-test.py`.
- AG CuteMusic: `cutemusic/agpm.py`, `cutemusic/link.py` (LinkDevices, LinkSender, LinkReceiver).
- AG CuteMusic, Linux only, the older sound-server path still beside it: `cutemusic/share.py` (PulseAudio /
  pipewire-pulse null sinks, the ALSA device `ag_cutemusic_mixer`, `alsa/60-ag-cute-music.conf`) and
  `cutemusic/apps.py` (another program's streams moved onto a sink of CuteMusic's: the CALL strip).

### Why it is replaced

- A sandboxed Blink (Blink Pro, Mac App Store) cannot reach the rings or the files in `$TMPDIR` of another app.
- Other programs (Spotify, a browser) cannot play into the mixer: the rings are Blink's only.
- Two transports on Linux (rings and sound-server devices), each with its own failure modes.


## v2: a device for Blink's microphone, the rest captured

### Principles

- **One device, input only, for Blink**: AG Podcast Mixer is Blink's microphone, nothing else. Blink plays the call
  on the headset as any call; it does not go through the device.
- **Other programs' sound is captured, not moved**: Spotify, Blink's call, any program, taken by AG CuteMusic
  without the program choosing a device (macOS: process taps; Linux: PipeWire links). The program may be muted at
  its own output while captured, so it is heard through the mixer with its fader.
- **The data goes with the device** on macOS (its custom properties: any process reads them, a sandboxed one too),
  over D-Bus on Linux. No shared files.
- The mixing stays in AG CuteMusic; the driver only moves data.

### macOS

**The driver** (an AudioServerPlugIn, `/Library/Audio/Plug-Ins/HAL/AGPodcastMixer.driver`), runs in coreaudiod:

| Device | Visible | Direction | Used by | Content |
|---|---|---|---|---|
| AG Podcast Mixer | yes | input, 2 ch | Blink (any app may) | the mix |
| AG Podcast Mixer Feed | hidden (`kAudioDevicePropertyIsHidden`) | output, 2 ch | AG CuteMusic, by UID | the mix, written |

- The two share one ring and one clock (the driver's zero timestamps): no drift between AG CuteMusic writing and
  Blink reading. The only clock boundary is AG CuteMusic's own output (the headset): GStreamer resamples there, as
  for any device.
- AG Podcast Mixer is alive (`kAudioDevicePropertyDeviceIsAlive`) only while a client has the Feed open: the mixer
  runs. That replaces `mixer.lock`. Blink always lists the device in its Devices menu, with the reason it is not
  usable in brackets when it is not alive or not installed.
- Silence when nothing writes; the ring sized for a few quanta (target under 20 ms through the driver).
- Base: libASPL (MIT, C++) or Apple's NullAudio sample. Not BlackHole (GPL-3).
- Installed by a signed, notarized `.pkg` (admin rights; `killall coreaudiod` after install). AG CuteMusic's
  macOS release becomes a .pkg, or the driver a .pkg of its own that the app offers to install.

**The data** — custom properties on the AG Podcast Mixer device (`kAudioObjectPropertyCustomPropertyInfoList`,
values `CFPropertyList`, kept by the driver as given, never interpreted); readers add property listeners (no
polling):

| Selector | Writer | Content |
|---|---|---|
| `agnp` nowPlaying | AG CuteMusic | `{title, artist, album, cover (hash or path), position, duration, state}` |
| `agcl` calls | Blink | `[{kind: "call", name, address, held}, {kind: "room", name, participants}]` (calls.json's) |
| `agmx` mixer | AG CuteMusic | `{power, toCalls, karaoke, muted: {...}, faders: {...}}` |
| `agrq` request | Blink | `{action: "show-mixer", id}` (show-mixer.request's): AG CuteMusic acts on a new id |
| `agbl` blink | Blink | `{pid, version}` while Blink runs (blink.lock's); cleared on quit |

Small values only (a few KB): the cover as a hash or path, never the image. Blink clears `agbl` and `agcl` on quit;
the driver clears a property written by a process whose client went away when it can tell (best effort; readers
also treat a stale `agbl` pid as gone).

**Capturing programs: process taps** (macOS 14.2+; `CATapDescription`, `AudioHardwareCreateProcessTap`, a private
aggregate device with the tap as its input, read by GStreamer's osxaudiosrc):

- The user grants AG CuteMusic the system audio recording permission once (`NSAudioCaptureUsageDescription`).
- One tap per program chosen (by bundle ID: Spotify, Blink, Blink Pro), stereo.
- Mute behaviour per strip: `CATapMutedWhenTapped` (heard only through the mixer, with its fader) or unmuted (heard
  as usual; the mixer only sends it to the call).
- Blink's call (the BLINK strip): a tap on Blink, muted when tapped, so it is heard through the mixer's fader and
  never sent back to the call (it is a strip of its own, not in the TO CALLS mix: the friends do not hear
  themselves).
- PyObjC may not cover the tap API: a small C / Objective-C extension (`cutemusic/_taps`) that makes the tap and the
  aggregate and returns the aggregate's AudioDeviceID / UID for GStreamer.

**Blink for macOS (Cocoa, sandboxed Blink Pro included)**: picks AG Podcast Mixer as its input like any device (no
SDK factory); echo cancelling off while it is the input; a one-line notice "Use a headset" when it is chosen; writes
`agcl`, `agbl`, `agrq`; reads `agnp` and `agmx` for its UI. Entitlement: microphone only (already there).

### Linux (PipeWire)

- **The device**: a PipeWire config fragment installed by the package
  (`/usr/share/pipewire/pipewire.conf.d/ag-podcast-mixer.conf`): a `support.null-audio-sink` "AG Podcast Mixer
  Feed" (AG CuteMusic plays the mix into it) and its monitor as the source "AG Podcast Mixer" (Blink's input; ALSA
  through pipewire-alsa / pipewire-pulse, as any source). Always there, not loaded and unloaded by AG CuteMusic.
  Replaces share.py's modules and the ALSA drop-in.
- **Capturing programs**: a program's output node linked to an extra input of AG CuteMusic's (a copy: the program
  plays where it was). To hear it only through the mixer's fader, AG CuteMusic moves the stream onto its own sink
  instead (apps.py today): a stream's volume applies to the copy and the original alike, so the original cannot be
  muted alone. Flatpak'd programs are streams like any other.
- **The data**: D-Bus, session bus, `org.agprojects.PodcastMixer` at `/org/agprojects/PodcastMixer`, properties
  `NowPlaying`, `Mixer` (AG CuteMusic), `Calls`, `Blink` (Blink, through a method `SetCalls` / `SetBlink`), a method
  `ShowMixer`; `PropertiesChanged` signals. Same contents as the macOS properties. AG CuteMusic's MPRIS stays for
  everyone else. A Flatpak'd Blink needs `--talk-name=org.agprojects.PodcastMixer`.

### Windows

Not in v2's first steps. The same split later: a virtual input device (a driver: the hard part on Windows) and
process loopback capture (`ActivateAudioInterfaceAsync`, process loopback, Windows 10 2004+) for programs.

### Removed in v2

Once v2 works end to end on both systems:

- SDK: `63_agpm_audio_device.patch`, Engine's `podcast_mixer_available` / `podcast_mixer_dir`, `tools/agpm.py`,
  `tools/agpm-test.py`.
- AG CuteMusic: `agpm.py`, `link.py`, share.py's module loading, `alsa/60-ag-cute-music.conf`, `blink_calls()`'s
  files.
- Blink Qt, Blink Cocoa: their `agpm.py` copies, `calls.json`, `blink.lock`, `show-mixer.request`.


## Work plan (macOS first)

1. **Taps in AG CuteMusic** (no driver needed; testable against the v1 ring link): `_taps` extension, a strip per
   tapped program, mute-when-tapped per strip; Spotify and Blink captured. Check: the permission prompt, a program
   started after the tap, a program quitting, the tap surviving a default-device change.
2. **The driver**: AG Podcast Mixer + Feed, one ring, alive while the Feed is open. AG CuteMusic writes the Feed
   (osxaudiosink by UID). Blink Cocoa (not sandboxed first, then Blink Pro) uses it as its input with echo
   cancelling off. Check: a 30-minute stereo call for drift and glitches; latency through the driver; AG CuteMusic
   quitting and coming back mid-call; coreaudiod restart.
3. **The properties**: `agcl`, `agbl`, `agrq` from Blink; `agnp`, `agmx` from AG CuteMusic; listeners both sides.
   Blink Pro sandboxed reads and writes them.
4. **Packaging**: the signed, notarized .pkg; AG CuteMusic offering the install when the driver is missing; Blink's
   Devices menu showing why AG Podcast Mixer is not usable.
5. **Linux**: the PipeWire fragment, link-based capture beside apps.py's move, the D-Bus service; Blink Qt and
   sylk-desktop on it.
6. **Removal**: everything under Removed in v2.

### Open points

- Whether the driver .pkg ships inside AG CuteMusic's DMG or as a download the app points to.
- How Blink Pro (App Store) tells the user to install a driver it cannot install itself.
- Process taps need macOS 14.2+: below that, no program capture (AG Podcast Mixer for Blink still works).
