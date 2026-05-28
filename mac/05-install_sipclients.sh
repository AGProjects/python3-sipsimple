#!/bin/bash
# Install sipclients3 from the local checkout. Expects the sipclients3
# directory to sit alongside python3-sipsimple, e.g.:
#
#     <parent>/
#         python3-sipsimple/   <- this repo (script lives in mac/)
#         sipclients3/         <- local sipclients3 checkout
#
# No git pull, no tarball download — we use whatever is on disk.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIPSIMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(cd "$SIPSIMPLE_DIR/.." && pwd)"
SIPCLIENTS_DIR="$PARENT_DIR/sipclients3"

if [ ! -d "$SIPCLIENTS_DIR" ]; then
    echo
    echo "Expected sipclients3 directory at: $SIPCLIENTS_DIR"
    echo "Place the sipclients3 checkout next to python3-sipsimple and retry."
    echo
    exit 1
fi

if [ ! -f "$SIPCLIENTS_DIR/setup.py" ] && [ ! -f "$SIPCLIENTS_DIR/pyproject.toml" ]; then
    echo
    echo "No setup.py or pyproject.toml found in: $SIPCLIENTS_DIR"
    echo "That doesn't look like a sipclients3 source tree."
    echo
    exit 1
fi

source "$SCRIPT_DIR/activate_venv.sh"

echo "Installing sipclients3 from $SIPCLIENTS_DIR ..."

# (pgpy, used by sip-session3, comes in via mac/python-requirements.txt in step 03.)
pip3 install --force-reinstall --no-deps --no-build-isolation "$SIPCLIENTS_DIR"

VENV="${VIRTUAL_ENV:-}"
BIN="$VENV/bin"

cat <<EOF

================================================================================
sipclients3 installed into the venv.

  Virtualenv:    $VENV
  CLI scripts:   $BIN/

The following sip-* commands are now available:
$(ls "$BIN" 2>/dev/null | grep -E '^sip-' | sed 's|^|    |')

How to use them:

  1) Activate the venv (recommended for an interactive session):

         source $SCRIPT_DIR/activate_venv.sh
         sip-register3 --help

     Leave the venv with: \`deactivate\`.

  2) Or call them directly with the full path:

         $BIN/sip-register3 --help

  3) Or put the venv's bin on PATH permanently in ~/.zshrc / ~/.bash_profile:

         export PATH="$BIN:\$PATH"

================================================================================
EOF
