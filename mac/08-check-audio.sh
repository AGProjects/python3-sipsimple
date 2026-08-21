#!/bin/bash
#
# Diagnose microphone / audio-device problems for the installed sipsimple
# build. Answers, in order, the three questions that explain almost every
# "no microphone" report on macOS:
#
#   1. Is this session even able to hold microphone access? A GUI Terminal
#      runs in the Aqua (gui/<uid>) launchd domain and its requests are
#      attributed to the terminal app. An ssh session runs in Background
#      (user/<uid>) and is attributed to sshd, which has no UI, cannot show
#      the consent dialog, and is refused without ever prompting.
#
#   2. Has this *user*, on this *machine*, granted access? TCC state is
#      per-user and per-machine, so a working MacBook Pro tells you nothing
#      about another Mac, and a freshly created account starts with none.
#      When access is denied macOS does NOT return an error to CoreAudio --
#      it hands over a stream of digital silence, so the call connects, the
#      codec negotiates, and the far end simply hears nothing.
#
#   3. Does the input device the client is configured to use still exist
#      under that name on this machine?
#
# Usage:
#     ./08-check-audio.sh                  # checks, plus capture test if allowed
#     ./08-check-audio.sh --no-record      # skip the capture test
#     ./08-check-audio.sh --force-record   # attempt capture even if denied
#                                          # (will block until the timeout)
#
# Every external command that can block is run under a watchdog, and INT/TERM
# tear down the child process group, so Ctrl-C always works.
#

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

do_record=1
force_record=0
case "${1:-}" in
    --no-record)    do_record=0 ;;
    --force-record) force_record=1 ;;
    -h|--help)      sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "")             ;;
    *)              echo "Unknown option '$1'. Run with --help." >&2; exit 2 ;;
esac

hr() { printf '%s\n' "--------------------------------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# Watchdog + signal handling.
#
# A denied microphone makes ffmpeg hang inside the avfoundation device open
# rather than returning an error, so any capture attempt must be bounded.
# CHILD is killed by the trap so Ctrl-C tears down the blocked child too,
# not just this script.
# ---------------------------------------------------------------------------
CHILD=""
TMPFILES=()

kill_child() {
    local sig="$1"
    # Negative pid targets the whole process group, so helpers ffmpeg spawns
    # die with it instead of being orphaned.
    kill "-$sig" "-$CHILD" 2>/dev/null || kill "-$sig" "$CHILD" 2>/dev/null || true
}

cleanup() {
    if [ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null; then
        kill_child TERM
        sleep 1
        kill_child KILL
    fi
    for f in ${TMPFILES+"${TMPFILES[@]}"}; do
        [ -n "$f" ] && rm -f "$f"
    done
}

on_interrupt() {
    echo
    echo "Interrupted - cleaning up."
    cleanup
    exit 130
}

trap on_interrupt INT TERM
trap cleanup EXIT

# run_with_timeout <seconds> <command...>
# Returns the command's status, or 124 if it had to be killed.
run_with_timeout() {
    local secs="$1"; shift
    set -m                  # give the child its own process group
    "$@" &
    CHILD=$!
    set +m
    local waited=0 rc=0
    while kill -0 "$CHILD" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            kill_child TERM
            sleep 1
            kill_child KILL
            wait "$CHILD" 2>/dev/null
            CHILD=""
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$CHILD"; rc=$?
    CHILD=""
    return $rc
}

hr
echo "1. Session context"
hr

echo "  user            : $(id -un)  (uid $(id -u))"
echo "  host            : $(hostname -s)"
echo "  macOS           : $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "  arch            : $(uname -m)"

remote=0
if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ]; then
    remote=1
    echo "  session         : SSH"
elif [ -n "${TMUX:-}" ]; then
    remote=1
    echo "  session         : tmux (TCC attributes the request to the tmux server)"
elif [ "${TERM:-}" = "screen" ]; then
    remote=1
    echo "  session         : screen (same caveat as tmux)"
else
    echo "  session         : local terminal"
fi

echo "  responsible app : ${TERM_PROGRAM:-unknown (no TERM_PROGRAM - normal over ssh)}"

# The definitive indicator: Aqua == gui/<uid>, Background == user/<uid>.
domain="unknown"
if command -v launchctl >/dev/null 2>&1; then
    domain=$(launchctl managername 2>/dev/null || echo unknown)
fi
echo "  launchd domain  : $domain"
case "$domain" in
    Aqua)       echo "                    GUI session - microphone CAN be granted here." ;;
    Background) echo "                    Headless/ssh - microphone is DENIED here by design."
                echo "                    Use 09-run-in-gui-session.sh to cross into Aqua."
                remote=1 ;;
esac

console_user=$(stat -f '%Su' /dev/console 2>/dev/null || echo unknown)
echo "  console user    : $console_user"
if [ "$console_user" = "root" ]; then
    echo "                    Nobody is logged in at the screen, so no Aqua"
    echo "                    session exists for any process to borrow."
fi

echo
hr
echo "2. Microphone authorization (TCC)"
hr

tcc_file=$(mktemp)
TMPFILES+=("$tcc_file")

/usr/bin/python3 - "$tcc_file" <<'PY'
# Ask AVFoundation directly through ctypes: works with the system python and
# needs no pyobjc. This is the same value the SIP client's request will get.
import ctypes, sys

STATUS = {0: "not determined (no prompt answered yet)",
          1: "restricted (MDM / parental controls)",
          2: "DENIED",
          3: "authorized"}

status = None
try:
    objc = ctypes.CDLL('/usr/lib/libobjc.dylib')
    av = ctypes.CDLL('/System/Library/Frameworks/AVFoundation.framework/AVFoundation')

    objc.objc_getClass.restype = ctypes.c_void_p
    objc.objc_getClass.argtypes = [ctypes.c_char_p]
    objc.sel_registerName.restype = ctypes.c_void_p
    objc.sel_registerName.argtypes = [ctypes.c_char_p]

    cls = objc.objc_getClass(b'AVCaptureDevice')
    sel = objc.sel_registerName(b'authorizationStatusForMediaType:')
    media_audio = ctypes.c_void_p.in_dll(av, 'AVMediaTypeAudio')

    msg = objc.objc_msgSend
    msg.restype = ctypes.c_long
    msg.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]

    status = msg(cls, sel, media_audio)
    print(f"  status          : {status} - {STATUS.get(status, 'unknown')}")
    if status == 3:
        print("  -> This session may use the microphone.")
    elif status == 0:
        print("  -> Nothing has asked yet on this account. Run this from a")
        print("     LOCAL Terminal window to raise the consent prompt.")
    elif status == 2:
        print("  -> Refused. macOS will feed the SIP client pure silence;")
        print("     nothing in the logs will look like an error.")
except Exception as exc:
    print(f"  (could not query AVFoundation: {exc})")

with open(sys.argv[1], 'w') as fh:
    fh.write('' if status is None else str(status))
PY

mic_status=$(cat "$tcc_file" 2>/dev/null || echo "")

echo
hr
echo "3. Input devices this machine reports"
hr
run_with_timeout 20 system_profiler SPAudioDataType > /tmp/.spaudio.$$ 2>/dev/null
TMPFILES+=("/tmp/.spaudio.$$")
if [ -s "/tmp/.spaudio.$$" ]; then
    awk '/^ *[A-Za-z].*:$/{d=$0} /Input Channels/{gsub(/^ +/,"",d); print "  " d}' "/tmp/.spaudio.$$" \
        | sort -u
else
    echo "  (system_profiler produced nothing or timed out)"
fi

echo
hr
echo "4. Devices as PJSIP sees them"
hr

if [ -f "$SCRIPT_DIR/activate_venv.sh" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/activate_venv.sh" >/dev/null 2>&1 || true
fi

pjsip_probe=$(mktemp)
TMPFILES+=("$pjsip_probe")
cat > "$pjsip_probe" <<'PY'
import sys, time
try:
    import sipsimple
    from sipsimple.core import Engine
except Exception as exc:
    print(f"  Could not import sipsimple: {exc}")
    sys.exit(0)

print(f"  sipsimple {sipsimple.__version__}")
e = Engine()
try:
    e.start(codecs=[], video_codecs=[])
    for _ in range(100):
        if e.is_running:
            break
        time.sleep(0.1)
    else:
        print("  Engine never came up.")
        sys.exit(0)

    def show(label, attr):
        items = getattr(e, attr, None)
        if items is None:
            print(f"  {label}: (not exposed by this build)")
            return
        names = [d.decode() if isinstance(d, (bytes, bytearray)) else str(d)
                 for d in items]
        print(f"  {label} ({len(names)}):")
        for n in names:
            print(f"    - {n}")

    show("Input devices", "input_devices")
    show("Output devices", "output_devices")
finally:
    try:
        e.stop()
        e.join(timeout=5)
    except Exception:
        pass
PY

# Engine startup touches the audio HAL and can itself stall on a denied mic.
( cd / && run_with_timeout 30 python3 "$pjsip_probe" )
if [ $? -eq 124 ]; then
    echo "  TIMED OUT after 30s - the engine stalled bringing up the audio device."
    echo "  On a denied-microphone session that is expected."
fi

echo
hr
echo "5. Configured device in the SIP client settings"
hr
cfg="$HOME/.sipclient/config"
if [ -f "$cfg" ]; then
    if grep -nE "input_device|output_device|alert_device" "$cfg"; then
        echo "  ^ if a name here is not in the list above, PJSIP falls back to a"
        echo "    null device and you get silence even with permission granted."
    else
        echo "  No explicit device pinned (using system default) - fine."
    fi
else
    echo "  $cfg not present yet (no SIP client has saved settings on this account)."
fi

echo
hr
echo "6. Live capture test"
hr

if [ "$do_record" -eq 0 ]; then
    echo "  Skipped (--no-record)."
elif [ "$mic_status" = "2" ] && [ "$force_record" -eq 0 ]; then
    echo "  Skipped: microphone access is denied for this session, so opening"
    echo "  the capture device would block until the watchdog kills it. That"
    echo "  hang IS the symptom - there is nothing more to learn from it."
    echo "  Re-run with --force-record if you want to see it for yourself."
elif ! command -v ffmpeg >/dev/null 2>&1; then
    echo "  ffmpeg not installed - skipping (sudo port install ffmpeg)."
else
    tmpwav=$(mktemp -t micchk)
    rm -f "$tmpwav"; tmpwav="$tmpwav.wav"
    TMPFILES+=("$tmpwav")

    echo "  Recording 2 seconds from the default input (10s watchdog) ..."
    run_with_timeout 10 ffmpeg -nostdin -hide_banner -loglevel error \
        -f avfoundation -i ":default" -t 2 -y "$tmpwav"
    rc=$?

    if [ "$rc" -eq 124 ]; then
        echo "  TIMED OUT - ffmpeg blocked opening the input device."
        echo "  That is the classic signature of refused microphone access."
    elif [ "$rc" -ne 0 ]; then
        echo "  ffmpeg exited $rc without producing audio."
    elif [ ! -s "$tmpwav" ]; then
        echo "  ffmpeg produced an empty file."
    else
        python3 - "$tmpwav" <<'PY'
import sys, wave, array
try:
    with wave.open(sys.argv[1]) as w:
        frames = w.readframes(w.getnframes())
        a = array.array('h')
        a.frombytes(frames[:len(frames) - len(frames) % 2])
except Exception as exc:
    print(f"  could not read the recording: {exc}")
    raise SystemExit(0)
# Signed 16-bit samples run -32768..32767, so full scale is 32768, not
# 32767; using the latter as the denominator prints "32768 / 32767".
FULL_SCALE = 32768
peak = max((abs(v) for v in a), default=0)
pct = 100.0 * peak / FULL_SCALE
print(f"  peak sample: {peak} / {FULL_SCALE}  ({pct:.1f}% of full scale)")
if peak == 0:
    print("  ALL ZEROS -- the OS is handing out digital silence. That is the")
    print("  signature of denied access, not a broken device or a bad build.")
else:
    print("  Non-zero audio captured: the microphone works for this session.")
    if peak >= FULL_SCALE:
        print()
        print("  NOTE: the signal hit full scale, i.e. it is clipping. That is")
        print("  fine as proof the mic works, but on a call it means distortion.")
        print("  Turn the input gain down in System Settings > Sound > Input,")
        print("  or move away from the microphone.")
    print("  If calls are still silent, the problem is device selection or")
    print("  routing inside the SIP client, not permissions.")
PY
    fi
fi

echo
hr
if [ "$remote" -eq 1 ]; then
    echo "This session runs in the Background launchd domain and can never be"
    echo "granted microphone access. Either run from a Terminal window opened"
    echo "on the machine itself, or use:"
    echo
    echo "    ./09-run-in-gui-session.sh ./08-check-audio.sh"
fi
echo "Done."
hr
