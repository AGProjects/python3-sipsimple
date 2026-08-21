#!/bin/bash
#
# Explicitly raise the macOS microphone consent dialog for the terminal app
# this runs under, and report the result.
#
# Why this is needed
# ------------------
# Recording tools like ffmpeg or sox open the capture device and, if no
# decision has been recorded yet, can simply receive silence instead of
# triggering the consent dialog. You are then stuck: the status stays
# "not determined" (0) forever, nothing appears in System Settings >
# Privacy & Security > Microphone -- because that list only shows apps that
# have actually *asked* -- and every recording is digital silence.
#
# This script asks properly. It builds a real AVCaptureSession against the
# default audio device and starts it, which is what makes TCC attribute the
# request to the responsible app (Terminal, iTerm, ...) and show the dialog.
# It then polls authorizationStatusForMediaType: until you answer.
#
# All of it goes through ctypes against the system Python, so there is
# nothing to install -- no pyobjc, no venv, no dependency on the sipsimple
# build being importable.
#
# Usage
# -----
#     ./10-request-mic-access.sh              # ask, wait up to 120s
#     ./10-request-mic-access.sh --timeout 30
#     ./10-request-mic-access.sh --reset      # forget the decision, then ask
#
# The dialog can only appear in a GUI (Aqua) session -- at the console or
# over Screen Sharing. This script refuses to run anywhere else, because in
# a Background/ssh session the request is refused before anything is shown.
#

set -eu

timeout=120
reset=0

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--timeout) timeout="${2:-}"; [ -n "$timeout" ] || { echo "Error: --timeout needs a value." >&2; exit 2; }; shift 2 ;;
        --timeout=*)  timeout="${1#--timeout=}"; shift ;;
        --reset)      reset=1; shift ;;
        -h|--help)    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "Error: unknown option '$1'. Run with --help." >&2; exit 2 ;;
    esac
done

case "$timeout" in
    ''|*[!0-9]*) echo "Error: --timeout must be a whole number of seconds." >&2; exit 2 ;;
esac

domain=$(launchctl managername 2>/dev/null || echo unknown)
if [ "$domain" != "Aqua" ]; then
    cat >&2 <<EOF
Error: this session is '$domain', not 'Aqua'.

       The consent dialog can only be shown in a GUI session. Connect with
       Screen Sharing (vnc://$(hostname -s).local), open Terminal there, and
       run this script from that window.
EOF
    exit 1
fi

echo "Terminal app : ${TERM_PROGRAM:-unknown}"
echo "User         : $(id -un) (uid $(id -u))"
echo

if [ "$reset" -eq 1 ]; then
    echo "Resetting the recorded microphone decision for this user ..."
    tccutil reset Microphone >/dev/null 2>&1 || true
    echo "  done - macOS will ask again."
    echo
fi

/usr/bin/python3 - "$timeout" <<'PY'
import ctypes, sys, time

TIMEOUT = int(sys.argv[1])

STATUS = {0: "not determined", 1: "restricted", 2: "denied", 3: "authorized"}

objc = ctypes.CDLL('/usr/lib/libobjc.dylib')
av = ctypes.CDLL('/System/Library/Frameworks/AVFoundation.framework/AVFoundation')
ctypes.CDLL('/System/Library/Frameworks/Foundation.framework/Foundation')

objc.objc_getClass.restype = ctypes.c_void_p
objc.objc_getClass.argtypes = [ctypes.c_char_p]
objc.sel_registerName.restype = ctypes.c_void_p
objc.sel_registerName.argtypes = [ctypes.c_char_p]


def cls(name):
    c = objc.objc_getClass(name.encode())
    if not c:
        raise RuntimeError(f"class {name} not found")
    return ctypes.c_void_p(c)


def sel(name):
    return ctypes.c_void_p(objc.sel_registerName(name.encode()))


def send(receiver, selector, *args, restype=ctypes.c_void_p, argtypes=()):
    """One configured objc_msgSend call. objc_msgSend is variadic, so the
    signature must be set per call site rather than once globally."""
    fn = objc.objc_msgSend
    fn.restype = restype
    fn.argtypes = [ctypes.c_void_p, ctypes.c_void_p] + list(argtypes)
    return fn(receiver, selector, *args)


AVMediaTypeAudio = ctypes.c_void_p.in_dll(av, 'AVMediaTypeAudio')
AVCaptureDevice = cls('AVCaptureDevice')

def status():
    return send(AVCaptureDevice, sel('authorizationStatusForMediaType:'),
                AVMediaTypeAudio,
                restype=ctypes.c_long, argtypes=[ctypes.c_void_p])

initial = status()
print(f"Current status: {initial} - {STATUS.get(initial, '?')}")

if initial == 3:
    print("Already authorized - nothing to do.")
    raise SystemExit(0)
if initial == 1:
    print("Restricted by policy (MDM or parental controls). A user cannot")
    print("override this; it has to be lifted by whoever manages the Mac.")
    raise SystemExit(1)
if initial == 2:
    print()
    print("Access was explicitly refused earlier, and macOS will not ask a")
    print("second time. Either flip it back on in System Settings >")
    print("Privacy & Security > Microphone, or clear the decision and rerun:")
    print("    ./10-request-mic-access.sh --reset")
    raise SystemExit(1)

# Build a real capture session. Merely querying status never prompts; the
# prompt comes from actually trying to use the device.
print()
print("Opening the default audio input to trigger the consent dialog ...")

device = send(AVCaptureDevice, sel('defaultDeviceWithMediaType:'),
              AVMediaTypeAudio, argtypes=[ctypes.c_void_p])
if not device:
    print("No default audio input device. Is a microphone connected?")
    raise SystemExit(1)

name_obj = send(ctypes.c_void_p(device), sel('localizedName'))
utf8 = send(ctypes.c_void_p(name_obj), sel('UTF8String'), restype=ctypes.c_char_p)
print(f"Device: {utf8.decode() if utf8 else 'unknown'}")

AVCaptureDeviceInput = cls('AVCaptureDeviceInput')
err = ctypes.c_void_p(0)
dev_input = send(AVCaptureDeviceInput, sel('deviceInputWithDevice:error:'),
                 ctypes.c_void_p(device), ctypes.byref(err),
                 argtypes=[ctypes.c_void_p, ctypes.c_void_p])

session = send(cls('AVCaptureSession'), sel('alloc'))
session = send(ctypes.c_void_p(session), sel('init'))

if dev_input:
    can_add = send(ctypes.c_void_p(session), sel('canAddInput:'),
                   ctypes.c_void_p(dev_input),
                   restype=ctypes.c_bool, argtypes=[ctypes.c_void_p])
    if can_add:
        send(ctypes.c_void_p(session), sel('addInput:'),
             ctypes.c_void_p(dev_input), argtypes=[ctypes.c_void_p])

send(ctypes.c_void_p(session), sel('startRunning'))

print()
print("=" * 72)
print("  A dialog should now be on screen, naming your terminal app:")
print("    \"... would like to access the microphone\"")
print("  Click OK / Allow.")
print("=" * 72)
print()
print(f"Waiting up to {TIMEOUT}s for your answer ...", flush=True)

deadline = time.time() + TIMEOUT
last = initial
while time.time() < deadline:
    cur = status()
    if cur != last:
        print(f"  status changed: {cur} - {STATUS.get(cur, '?')}")
        last = cur
    if cur in (2, 3):
        break
    time.sleep(0.5)

send(ctypes.c_void_p(session), sel('stopRunning'))

final = status()
print()
print(f"Final status: {final} - {STATUS.get(final, '?')}")

if final == 3:
    print()
    print("Granted. Terminal now appears in System Settings > Privacy &")
    print("Security > Microphone, and the grant persists across reboots.")
    print("Verify with:  ./08-check-audio.sh")
    print("From ssh:     ./09-run-in-gui-session.sh ./08-check-audio.sh")
    raise SystemExit(0)
elif final == 2:
    print()
    print("Refused. Turn it back on in System Settings > Privacy & Security >")
    print("Microphone, or run this again with --reset.")
    raise SystemExit(1)
else:
    print()
    print("Still undecided - no dialog was answered.")
    print()
    print("If no dialog ever appeared, the terminal app itself is likely")
    print("missing its TCC registration. Things to try, in order:")
    print("  1. Quit the terminal app completely (Cmd-Q) and reopen it.")
    print("  2. Run this from Apple's Terminal.app rather than a third-party")
    print("     terminal, which may not be registered as a TCC client.")
    print("  3. Check what is being refused, in another window:")
    print("       log stream --predicate 'subsystem == \"com.apple.TCC\"' --info")
    raise SystemExit(1)
PY
