# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`python3-sipsimple` is the SIP SIMPLE SDK (AG Projects) — a Python 3 library for building
real-time communications applications on SIP: audio/video (RTP), instant messaging & file
transfer (MSRP), screen sharing, and presence (XCAP/PIDF). This is an ONDEWO fork; the current
branch work (`OND236-70-...`) targets Python 3.12 and a loguru-based logging refactor.

The library is a **Cython/C extension wrapping the PJSIP stack** — most runtime behavior lives in
native code compiled from `.pyx`/`.pxi` sources against a locally-fetched PJSIP + ZRTP tree.
Nothing works until the C dependencies are fetched, patched, and the extension is built.

## Build & develop

The extension **must** be compiled before the package is usable. There is no test suite in-tree.

```sh
./get_dependencies.sh      # fetch PJSIP 2.10 + ZRTPCPP into deps/pjsip, apply deps/patches/*.patch
./build_inplace            # get_dependencies.sh + `setup.py build_ext --inplace` (fast dev loop)
```

- `build_inplace` is the normal iteration command — it rebuilds the C extension in place so
  `import sipsimple` works from the repo root.
- `get_dependencies.sh` is **destructive**: it re-extracts `deps/2.10.tar.gz`, deletes and recreates
  `deps/pjsip/`, and applies every patch in `deps/patches/` in filename order. Re-running after local
  edits to `deps/pjsip/` wipes them. It's idempotent for the downloads (skips if archive/ZRTPCPP exist).
- `deps/patches/*.patch` are the fork's real modifications to PJSIP (TLS log fix, VPX, ffmpeg 5.1,
  Mac audio) — edit behavior of the native layer by editing/adding a patch here, not by editing
  `deps/pjsip/` directly (that dir is regenerated).
- Debian package build: `./makedeb.sh` (runs `debuild` under `dist/`; needs `equivs` + `mk-build-deps`).

### System prerequisites

C toolchain + Python 3 dev headers, `openssl` and `ffmpeg` dev packages, plus the AG Projects
Python deps that are **not on PyPI**: `python3-application`, `python3-eventlib`, `python3-gnutls`,
`python3-otr`, `python3-msrplib`, `python3-xcaplib` (from download.ag-projects.com). PyPI deps:
cython, dnspython, lxml, twisted, python-dateutil, greenlet, zope.interface, requests.
See `docs/Install.linux` and `docs/Dependencies.txt`.

## Architecture

### The C core (`sipsimple/core/`)
The heart of the SDK. `_core.pyx` + the `_core.*.pxi` include files (one per concern:
`invitation`, `sdp`, `subscription`, `mediatransport`, `sound`, `video`, `headers`, …) compile into
`sipsimple.core._core`, a Cython wrapper over PJSIP. `_engine.py` runs the `Engine` — a `Singleton`
`Thread` that drives the PJSIP event loop and is configured via `Engine.default_start_options`
(ports, codecs, TLS, RTP port range, event packages). `core/__init__.py` **pins the expected PJSIP
revision** (`required_revision = 210`) and raises `ImportError` on mismatch — bumping PJSIP means
updating this constant and the fetch/patch scripts together.

### Application lifecycle (`sipsimple/application.py`)
`SIPApplication` is the top-level `Singleton` that starts/stops all subsystems in order:
storage → configuration → engine → managers (Account, Addressbook, DNS, Session) → audio/video
devices. Everything is event-driven through `application.notification.NotificationCenter`
(observer pattern via `zope.interface`), and Twisted's `reactor` runs on a dedicated thread.
Follow the notification flow, not linear call chains, to trace behavior.

### Concurrency model
Three cooperating worlds — get the thread boundary right or you'll deadlock/crash:
- **Twisted reactor thread** — signaling; use `@run_in_twisted_thread`.
- **eventlib/greenlet green threads** — blocking-style network ops (e.g. account registration,
  DNS); use `@run_in_green_thread` (`sipsimple/threading/green.py`). Recent commits deliberately
  moved operations like account delete into green threads.
- **`ThreadManager` worker threads** — `@run_in_thread('name')` for serialized background work.
These decorators live in `sipsimple/threading/`. PJSIP core calls must not be made from arbitrary
threads.

### Subsystems
- `account/` — `Account` / `BonjourAccount` / `AccountManager`; each account is a tree of
  `SettingsGroup`s (auth, SIP, SRTP, RTP, NAT, presence, XCAP…). Sub-packages handle SIP
  `registration`, `subscription`, `publication`, and `xcap`/`bonjour`.
- `session.py` — `Session` / `SessionManager`: the SIP dialog/offer-answer state machine tying
  signaling to media streams.
- `streams/` — media stream implementations grouped by transport: `rtp/` (audio, video) and
  `msrp/` (chat, filetransfer, screensharing). A `Session` combines multiple streams.
- `configuration/` — typed settings framework (`settings.py`, `datatypes.py`) with pluggable
  `backend/` persistence (`file`, `memory`).
- `payloads/` — generators/parsers for the XML bodies of every supported SIP event package
  (pidf, dialoginfo, resourcelists, watcherinfo, conference, …), validated against
  `payloads/xml-schemas/`.
- `lookup.py` / `lookup-gevent.py` — RFC 3263 DNS resolution with failover (`DNSManager`).
- `audio.py` / `video.py` — device + conference-bridge abstractions over the core mixer.

### Logging
`sipsimple/__init__.py` imports `sipsimple.logging.log` **first**, before anything else loads, so a
named logger (`application.log.get_logger('sipsimple')`) is available early. The ONDEWO fork is
migrating this toward loguru (`ondewo-logging`) — see recent history.

## Conventions & gotchas

- Generated C (`sipsimple/core/_core.c`, `sipsimple/util/_sha1.c`) and `build/`, `dist/`, `test/`
  are build artifacts, not source — `.boring` lists them; never edit or commit them.
- `Singleton` metaclass is used pervasively (Engine, SIPApplication, managers) — there is one
  global instance; don't construct a second.
- Version lives in `sipsimple/__info__.py` (`__version__`); `setup.py` reads it. Debian version is
  tracked separately in `debian/changelog`.
