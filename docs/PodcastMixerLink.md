# AG Podcast Mixer link

How AG CuteMusic's mixer and Blink exchange audio and call data: the mixer's mix is Blink's microphone in a call,
what the call plays is the mixer's BLINK strip, and each side knows what the other is doing (what plays, who is in
the call).

A real audio device for Blink's microphone (a driver on macOS, PipeWire nodes on Linux), other programs' sound
captured without a device, and the call data exchanged through the device (macOS) or D-Bus (Linux). (It replaced a
shared-memory ring link, "v1", removed in Nov 2026 before any release: see Removed.)

Device name: **AG Podcast Mixer**. Audio: 48 kHz, stereo. A headset is required: Blink's echo cancelling is
off while AG Podcast Mixer is the input device.


## Design: a device for Blink's microphone, the rest captured

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
- Both devices are in and out (driver 1.0.3): "AG Podcast Mixer" (Blink's: the mix in, the call out) and "AG Podcast
  Mixer Feed" (AG CuteMusic's: the mix out, the call in), two rings between them on the one clock. What Blink plays
  on it is AG CuteMusic's BLINK strip, read from the Feed's input (heard there, never mixed back into what Blink
  gets). Blink chooses it in its menu of devices for both, at the top.
- AG Podcast Mixer is always there (driver 1.0.2): Blink is set to it once and left so. While the mixer is off (the
  Feed not playing) it reads silence; the mix as soon as the mixer comes up, whether Blink started before or after.
  Blink never switches away from it on its own. (1.0.0-1.0.1 published it only while the Feed ran, as v1's
  mixer.lock did.) The Feed is listed, not hidden: GStreamer's osxaudiosink opens only devices of
  kAudioHardwarePropertyDevices; it cannot be a default device, and Blink leaves it out of its menus.
- The ring is indexed by sample time on the shared clock: the Feed's frame for sample time T is the input's frame
  for T; a frame not written reads as silence, never stale data. 16384 frames (also the zero timestamp period);
  the latency is the HAL's two IO buffers, not the ring's size.
- 48 kHz only (a client asking another rate is refused), float32, stereo, on both devices.
- Base: libASPL (MIT, C++), vendored in AG CuteMusic's `macos/driver/libASPL` and compiled into the driver.
- Installed by AG CuteMusic itself (see Installing the driver below), no .pkg.

**The data** (the plan; as built: see Status below) — custom properties on the AG Podcast Mixer device (`kAudioObjectPropertyCustomPropertyInfoList`,
values `CFPropertyList`, kept by the driver as given, never interpreted); readers add property listeners (no
polling):

| Selector | Writer | Content |
|---|---|---|
| `agnp` nowPlaying | AG CuteMusic | `{title, artist, album, cover (hash or path), position, duration, state}` |
| `agcl` calls | Blink | `[{kind: "call", name, address, held, rtt, loss_rx, loss_tx}, {kind: "room", name, participants}]` (calls.json's) |
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

**Installing the driver** — the driver is in AG CuteMusic's bundle (`Contents/Resources/AGPodcastMixer.driver`,
signed with the app by `sign-app.sh` and covered by its notarization); from a checkout, `build/driver/`
(`macos/driver/build.sh`):

- Play -> Install AG Podcast Mixer driver... / Update ... (the installed `CFBundleVersion` older than the
  app's) / Remove ...; at start, the install or the update offered once per version the app carries.
- One `osascript ... with administrator privileges`: the driver copied beside the installed one (`ditto`),
  `root:wheel`, swapped in, coreaudiod restarted (`killall coreaudiod`: launchd starts it
  again; `launchctl kickstart` is refused with SIP on). The sound stops for a moment on every device. `macos/driver/install.sh` does the same by
  hand.
- AG CuteMusic then builds its link again: on the Feed once coreaudiod has loaded the driver.
- Blink Pro, which can install nothing: "AG Podcast Mixer (install the driver from AG CuteMusic's Play menu)".
- Driver versions: `DRIVER_VERSION` in `macos/driver/CMakeLists.txt`, raised with every change to the driver.

### Linux (PipeWire)

The macOS pieces as built, one by one, and what each is on Linux (as built, Nov 2026, unless marked not yet). Blink
Qt (and Sylk Desktop) on the Blink side.

| macOS (as built) | Linux |
|---|---|
| AG Podcast Mixer + Feed (driver, hidden) | a PipeWire config fragment, installed by the package (AG CuteMusic's `pipewire/ag-podcast-mixer.conf`, in `/usr/share/pipewire/pipewire.conf.d/`), always there: `ag_podcast_mixer_feed` "AG Podcast Mixer Feed", a sink AG CuteMusic plays the mix into (pipewiresink by node name, `link.py` NodeOutput), looped back (libpipewire-module-loopback) as `ag_podcast_mixer` "AG Podcast Mixer", the source Blink records; `ag_podcast_mixer_call` "AG Podcast Mixer Call", a sink Blink plays the call into, its monitor read by AG CuteMusic (the BLINK strip). The Feed is needed: WirePlumber links a playback stream only to a sink (one targeting a virtual source went to the default sink). Required: without them (PipeWire not restarted since the install) there is no device; Blink's menu item says to log in again |
| (Blink's SIP audio) | the SDK has only ALSA on Linux: Blink reaches the nodes through the ALSA PCM `ag_cutemusic_mixer` described "AG Podcast Mixer" (`/etc/alsa/conf.d/60-ag-cute-music.conf`, PipeWire's ALSA plugin, `playback_node` / `capture_node` by name). Blink Qt's WebRTC rooms use pipewiresrc / pipewiresink on the nodes by name (`blink/webrtc/videoroom.py`). Blink Qt lists the device while the nodes are there (`pactl`), in the Devices menu's combined section only |
| hidden devices | none in PipeWire: node properties (`node.description`, a `media.class` other apps skip, or `priority.session` 0) keep them out of defaults; Blink Qt lists only the Mixer, AG CuteMusic only the Feeds, both by node name |
| AG Podcast Streaming + Feed (`agst`) | a second loopback in the same fragment, always there (a streaming app set up once, before, and left so): `ag_podcast_streaming_feed` "AG Podcast Streaming Feed", a sink AG CuteMusic plays the recorder's mix into while STREAMING is on (`recorder.py` start_streaming, NodeOutput), looped back as `ag_podcast_streaming` "AG Podcast Streaming", the source a streaming app (OBS...) records; silent while STREAMING is off. No `agst`: nothing to add or remove |
| `agvs` (Sylk Desktop) | not needed: Chromium lists PipeWire sources |
| `agbc`, `agrq`, `agst` (properties) | D-Bus, session bus, `org.agprojects.PodcastMixer` at `/org/agprojects/PodcastMixer` (AG CuteMusic's `cutemusic/bus.py`, behind `control.py`'s `blinks()` / `request()`): owned by AG CuteMusic; method `SetCalls(i pid, s json)` (agbc's json as is; an empty json on quit), `GetCalls() -> s` (`{"<pid>": <json>}`), `ShowMixer()` (Blink's notice about the device), signal `Request(s json)` (agrq's json). Blink Qt (`blink/cutemusic.py` CallPublisher) sets its calls on every call event and every 2 s (a keep-alive); an entry not set for 10 s, or whose process is gone, is left out. `Streaming` (agst) not yet. A Flatpak'd Blink needs `--talk-name=org.agprojects.PodcastMixer` |
| `hal.py` C I/O, FeedReceiver | GStreamer: `pipewiresink` into the Feed by node name (`link.py` NodeOutput), the BLINK strip `pulsesrc` on `ag_podcast_mixer_call.monitor`: no C needed. LinkSender paced by the clock (pipewiresink takes buffers in bursts of the graph's cycle: what waits in front of it cannot pace the sender) |
| `taps.py` (process taps) | not yet: link the program's output node to an extra input of AG CuteMusic (a copy: it still plays where it was), or move its stream onto a sink of ours to hear it only through the fader (apps.py today) |
| Spotify/Music over AppleScript | MPRIS (Spotify on Linux has it): play/pause, next, previous, now playing, volume |
| Recorder, mixing, mixer UI | shared code: unchanged |

**Work plan for Linux** (on the Ubuntu machine):

1. Done: the PipeWire fragment (Feed, its loopback the Mixer, Call); checked with `pw-cli ls Node`,
   `pactl list short sources`, `pactl list short sinks`. The streaming pair (Streaming Feed, its loopback AG Podcast Streaming) too.
2. Done: AG CuteMusic's link on the Feed and Call nodes (`link.py` LinkDevices / NodeOutput); STREAMING playing the
   recorder's mix into the Streaming Feed.
3. Done: the D-Bus service in AG CuteMusic (`bus.py`): `SetCalls`, `GetCalls`, `ShowMixer`, `Request`; `control.py`'s
   functions on top of it. (No `Streaming`: the streaming nodes are always there.)
4. Done: Blink Qt, the Mixer as its device, `SetCalls` on every call event (and every 2 s) with the same json as
   Blink Cocoa, End and Redial from `Request`; WebRTC rooms on the nodes.
5. Audio Apps: linking a program's node (pw-link) beside apps.py's move; MPRIS for the player's remote.
6. Sylk Desktop: the Mixer as a source (Chromium lists it); later `SetCalls` through D-Bus from Electron's main process.
7. Done: v1's removal (below).

### Windows

Not in v2's first steps. The same split later: a virtual input device (a driver: the hard part on Windows) and
process loopback capture (`ActivateAudioInterfaceAsync`, process loopback, Windows 10 2004+) for programs.

### Removed (v1, Nov 2026)

The shared-memory ring link (two rings, `to-call.ring` and `from-call.ring`, in a per-user directory, made an audio
device by an SDK patch) and its files (`mixer.lock`, `blink.lock`, `calls.json`, `blink.request`,
`show-mixer.request`). Nothing of it was released:

- SDK: `63_agpm_audio_device.patch` (patch 67 now stands alone, macOS only), Engine's `podcast_mixer_device` /
  `podcast_mixer_available` / `podcast_mixer_dir`, `tools/agpm.py`, `tools/agpm-test.py`.
- AG CuteMusic: `agpm.py`, the rings in `link.py` (LinkReceiver), share.py's PulseAudio modules (a fallback without
  the PipeWire nodes) and the mic's and player's sink "share", the file channel. Not `alsa/60-ag-cute-music.conf`:
  on Linux Blink's SIP audio reaches the nodes only through it.
- Blink Qt: `blink/agpm.py`, `blink/webrtc/podcast_mixer.py`, the file channel.
- Blink Cocoa: `CuteMusic.py`'s link-directory code (`blink.lock`, `calls.json`, `blink.request`,
  `show-mixer.request`) is dead (no link directory without patch 63): still to be removed.


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
5. **Linux**: see Linux (PipeWire) above, its work plan.
6. **Removal**: done (Removed, above).

### Status: macOS, as built (driver 1.3.0, AG CuteMusic 1.1.6)

What runs today; where it differs from the plan above, this is what the code does.

**The driver** (AG CuteMusic's `macos/driver/AGPodcastMixer.cpp`, libASPL):

| Device | UID | Listed | Direction | Used by |
|---|---|---|---|---|
| AG Podcast Mixer | `com.ag-projects.podcast-mixer.input` | hidden; listed while `agvs` is "1" | in + out | Blink (by UID: SDK patch 67), Sylk Desktop (while listed) |
| AG Podcast Mixer Feed | `com.ag-projects.podcast-mixer.feed` | hidden | out + in | AG CuteMusic (by id: `hal.py`, the C I/O) |
| AG Podcast Streaming | (driver's) | listed, may be the default input | in | any streaming app (OBS...) |
| AG Podcast Streaming Feed | `com.ag-projects.podcast-mixer.streaming-feed` | hidden | out | AG CuteMusic (the recorder's mix) |

- Two rings on one clock join the Mixer and its Feed: the mix (Feed out → Mixer in, Blink's microphone) and the call
  (Mixer out → Feed in, the BLINK strip). A third ring joins the two Streaming devices; both exist only while
  streaming.
- Hidden devices: other apps never offer them. Blink's SDK adds the Mixer by its UID (`67_agpm_driver_hidden_device.patch`,
  `ca_hidden_podcast_mixer()` in `coreaudio_dev.m`). AG CuteMusic opens the Feeds by id through CoreAudio, not GStreamer
  (osxaudio lists only listed devices).
- Versions: `DRIVER_VERSION` in `macos/driver/CMakeLists.txt` (a plain variable: a cached one kept its first value,
  every build said 1.0.0).

**The control channel**: custom properties (CFString) instead of the planned `agnp`, `agcl`, `agmx`, `agbl`:

| Selector | On | Writer | Content |
|---|---|---|---|
| `agbc` | Mixer | each Blink | `"<pid> <json>"` every 2 s and at once on a change of call state; `"<pid>"` alone on quit. Read: `{"<pid>": <json>}`, entries not set again for a while left out (a Blink that crashed) |
| `agrq` | Mixer | AG CuteMusic | `{"seq", "pid", "op": "hangup", "id"}` or `{"seq", "pid", "op": "redial"}`; the named Blink acts on a seq it has not seen |
| `agst` | Feed | AG CuteMusic | "1" / "0": the two Streaming devices added / removed |
| `agvs` | Feed | AG CuteMusic | "1" / "0": the Mixer listed for every app / hidden (Sylk Desktop runs) |

A Blink's json (Blink Cocoa `CuteMusic.py`, `_calls()` and `_redial()`): `{"calls": [{"kind": "call", "id",
"name", "address", "held", "state"?, "started"?, "rtt"?, "loss_rx"?, "loss_tx"?}], "redial": {"address",
"name"}}`. `state` while not connected (dialing, calling, ringing, incoming, adding audio, hanging up), `started`
(epoch seconds) once connected, the quality figures once measured. `address` is always user@domain, never with
`sip:`; `name` only a real display name. (Its v1 `calls.json` / `blink.lock` code is dead: see Removed.)

**AG CuteMusic**:

- `hal.py` + `macos/feedio/feedio.c` (`_feedio.dylib`, built by `macos/feedio/build.sh`): the Feeds' I/O in C
  (CoreAudio IOProc, lock-free rings, 5 ms cycles), no Python on the real-time thread; a Python IOProc fallback with
  longer cycles when the dylib is missing. `feedio_mix()`: the mixers' saturated sum, in C.
- `link.py` LinkSender: the mix sent to Blink, paced by the Feed (written as it takes it, 10 ms queued). Each input
  is buffered as deep as its pushes plus 5 ms (the mic 15 ms, a tapped app 45 ms); one running ahead loses a frame
  per quantum, one that ran dry is buffered again. No input waits for another.
- `recorder.py` Recorder: the same mixing of every strip, on the wall clock, into a file (FLAC, else MP3, else WAV)
  and, while STREAMING is on, into the Streaming Feed. Saved as `<music folder>/<genre>/<artist>/<title>`, tagged:
  in a call genre Blink Calls, artist the party's address; else My Memos, the Mac user.
- `control.py`: the properties (ctypes), the `agbc` listener, `set_streaming()`, `set_mixer_visible()`,
  `sylk_running()` (bundle id `com.agprojects.Sylk`).
- `taps.py`: the Audio Apps strip (process taps, macOS 14.2+), Spotify and Music driven over AppleScript.

**Blink Cocoa**: `CuteMusic.py` publishes `agbc`, acts on `agrq` (hangup ends the whole session; redial), keeps the
alert device off the AG devices. Its device menus show only AG Podcast Mixer, in the combined section, never the
Feeds or Streaming.

**Sylk Desktop**: nothing of its own yet: it sees the Mixer while it runs (`agvs`), chosen by hand. Its calls are
not on the strip; End and Redial do not reach it.

### Open points

- `agvs` toggles `kAudioDevicePropertyIsHidden` in place (no remove and add, so Blink's IO is undisturbed). Whether
  every HAL client sees the change without a restart is to be checked.
- Sylk Desktop in the control channel: a native helper (C or Swift) for Electron to set and listen to the properties.
- Hard clipping when several loud strips are summed: a limiter if it is heard.
- `corespeechd` and `avconferenced` may spin after a coreaudiod restart (the driver's install and removal).
