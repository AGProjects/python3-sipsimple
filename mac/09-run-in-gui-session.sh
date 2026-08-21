#!/bin/bash
#
# Run a command inside the console user's GUI (Aqua) session, so it can use
# the microphone when invoked over ssh.
#
# Why this is needed
# ------------------
# macOS puts a GUI Terminal in the Aqua / gui/<uid> launchd domain and an ssh
# session in Background / user/<uid>. TCC attributes a microphone request to
# the session's responsible process: Terminal.app in the first case, sshd in
# the second. sshd has no UI, cannot show the consent dialog, and is refused
# outright -- and the refusal is silent: CoreAudio keeps working and simply
# delivers digital silence.
#
# There is no way to pre-authorise around this. Microphone (along with Camera,
# ListenEvent and ScreenCapture) is excluded from PPPC pre-approval; even MDM
# on an enterprise-owned Mac can only *deny* those, never *allow*. So the only
# route is to hand the work to a process that lives in the Aqua session, which
# is what `launchctl asuser` does.
#
# Requirements
# ------------
#   * Somebody must be logged in at the screen -- an Aqua session has to exist.
#     For an unattended machine, turn on automatic login:
#       System Settings > Users & Groups > Automatically log in as ...
#   * The microphone must have been granted ONCE, interactively, in that GUI
#     session (at the console or over Screen Sharing). This script cannot do
#     that part for you: the consent dialog needs a human. Run
#     ./08-check-audio.sh there and answer the prompt.
#
# Usage
# -----
#   ./09-run-in-gui-session.sh <command> [args...]
#
#   ./09-run-in-gui-session.sh ./08-check-audio.sh
#   ./09-run-in-gui-session.sh "$VIRTUAL_ENV/bin/sip-session3" sip:bob@example.com
#
# Options
#   -u, --user USER   run as this user (default: the console user)
#   -q, --quiet       don't print the diagnostic preamble
#   -h, --help        this help
#
# Runs the command directly, without sudo or launchctl, when already in Aqua,
# so the same invocation is correct locally and over ssh.
#

set -eu

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

target_user=""
quiet=0

while [ $# -gt 0 ]; do
    case "$1" in
        -u|--user)  target_user="${2:-}"; [ -n "$target_user" ] || { echo "Error: --user needs a value." >&2; exit 2; }; shift 2 ;;
        --user=*)   target_user="${1#--user=}"; shift ;;
        -q|--quiet) quiet=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        --)         shift; break ;;
        -*)         echo "Error: unknown option '$1'. Run with --help." >&2; exit 2 ;;
        *)          break ;;
    esac
done

if [ $# -eq 0 ]; then
    echo "Error: no command given." >&2
    echo "Usage: $(basename "$0") <command> [args...]" >&2
    exit 2
fi

say() { [ "$quiet" -eq 1 ] || echo "$@"; }

# ---------------------------------------------------------------------------
# Already in the GUI session? Then there is nothing to cross over to.
# ---------------------------------------------------------------------------
current_domain=$(launchctl managername 2>/dev/null || echo unknown)
if [ "$current_domain" = "Aqua" ]; then
    say "Already in the Aqua session - running directly."
    exec "$@"
fi

say "Session is '$current_domain' - crossing into the GUI session."

# ---------------------------------------------------------------------------
# Who owns the GUI session?
# ---------------------------------------------------------------------------
console_user=$(stat -f '%Su' /dev/console 2>/dev/null || echo "")

if [ -z "$target_user" ]; then
    target_user="$console_user"
fi

if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
    cat >&2 <<EOF

Error: nobody is logged in at the screen, so there is no Aqua session to
       run in (console user is '${console_user:-unknown}').

       A macOS machine cannot serve audio truly headlessly. Enable automatic
       login so a GUI session always exists after boot:

           System Settings > Users & Groups > Automatically log in as ...

       or log in over Screen Sharing and leave the session running.
EOF
    exit 1
fi

if ! id "$target_user" >/dev/null 2>&1; then
    echo "Error: no such user '$target_user'." >&2
    exit 1
fi

if [ -n "$console_user" ] && [ "$target_user" != "$console_user" ]; then
    echo "Warning: '$target_user' is not the console user ('$console_user')." >&2
    echo "         launchctl asuser will fail unless that user has a session." >&2
fi

target_uid=$(id -u "$target_user")

# ---------------------------------------------------------------------------
# launchctl asuser needs root.
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    say "Re-running under sudo (launchctl asuser requires root) ..."
    # Note: ${quiet:+-q} would expand for quiet=0 too, since it tests for a
    # non-empty value rather than a true one. Build the flag list explicitly.
    reexec_flags=()
    [ "$quiet" -eq 1 ] && reexec_flags+=(-q)
    exec sudo -- "$0" ${reexec_flags+"${reexec_flags[@]}"} --user "$target_user" -- "$@"
fi

# Resolve the command to an absolute path while we can still see the caller's
# PATH; the Aqua session's PATH is different and often much shorter.
cmd="$1"; shift
if [ "${cmd#/}" = "$cmd" ]; then
    resolved=$(command -v "$cmd" 2>/dev/null || true)
    if [ -n "$resolved" ]; then
        case "$resolved" in
            /*) cmd="$resolved" ;;
            *)  cmd="$(cd "$(dirname "$resolved")" && pwd)/$(basename "$resolved")" ;;
        esac
    fi
fi

if [ ! -x "$cmd" ]; then
    echo "Error: '$cmd' is not an executable file." >&2
    exit 127
fi

say "  console user : $target_user (uid $target_uid)"
say "  command      : $cmd $*"
say

# `launchctl asuser <uid>` dispatches into that user's gui/<uid> domain; the
# inner `sudo -u` drops root back down so the process runs as the user (and
# therefore against that user's TCC grants, not root's).
exec launchctl asuser "$target_uid" sudo -u "$target_user" -- "$cmd" "$@"
