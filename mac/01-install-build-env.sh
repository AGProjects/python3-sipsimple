#!/bin/bash
#
# 01-install-build-env.sh — verify the prerequisites for building
# python3-sipsimple on macOS. Checks only; it installs nothing.
#
# Read-only and idempotent: run it as often as you like.

set -u

fail=0

note_missing() {
    fail=1
    echo
    echo "  MISSING: $1"
    shift
    while [ $# -gt 0 ]; do echo "           $1"; shift; done
}

# --- Python ----------------------------------------------------------------
# 03-install-python-deps.sh creates the venv with the stdlib `venv` module, so
# the third-party `virtualenv` package is no longer needed.
PYVER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
case "$PYVER" in
    3.9|3.10|3.11|3.12|3.13)
        ;;
    "")
        note_missing "python3 not found." \
                     "Install from https://www.python.org/"
        ;;
    *)
        note_missing "Python $PYVER is not supported (need 3.9 - 3.13)." \
                     "Install from https://www.python.org/"
        ;;
esac

if [ -n "$PYVER" ] && ! python3 -c "import venv" 2>/dev/null; then
    note_missing "Python's stdlib venv module." \
                 "Re-install Python 3 from https://www.python.org/ (its installer" \
                 "ships venv), or install your distro's python3-venv package."
fi

# --- MacPorts --------------------------------------------------------------
command -v port >/dev/null 2>&1 || \
    note_missing "MacPorts (port)." \
                 "Install from https://www.macports.org"

# --- Xcode command line tools ----------------------------------------------
# otool / lipo / install_name_tool are used throughout the build and by
# 02-install-c-deps.sh to verify architectures.
for t in otool lipo install_name_tool codesign; do
    command -v "$t" >/dev/null 2>&1 || \
        note_missing "$t (Xcode command line tools)." \
                     "Install with: xcode-select --install"
done

# --- cmake (optional) ------------------------------------------------------
# Only 02b-install-bcg729.sh needs it, and that script fails soft, so this is
# a warning rather than an error.
if ! command -v cmake >/dev/null 2>&1; then
    echo
    echo "  NOTE: cmake not found — 02b-install-bcg729.sh will skip the G.729"
    echo "        codec. Install with: sudo port install cmake"
fi

# --- Report ----------------------------------------------------------------
echo
if [ "$fail" -ne 0 ]; then
    echo "Build prerequisites are NOT satisfied."
    exit 1
fi

echo "All build prerequisites OK."
echo "  python3:  $(command -v python3)  ($(python3 -V 2>&1))"
echo "  port:     $(command -v port)"
echo "  otool:    $(command -v otool)"
[ -n "$(command -v cmake)" ] && echo "  cmake:    $(command -v cmake)"
echo
echo "Next: ./02-install-c-deps.sh"
