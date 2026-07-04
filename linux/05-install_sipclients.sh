#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/activate_venv.sh"

# Pull the current master tip — sipsimple stays in sync with the latest
# AG Projects dependencies, no need to pin a tag. (pgpy, used by
# sip-session3, comes in via linux/python-requirements.txt in step 03.)
pip3 install --no-build-isolation \
    https://github.com/AGProjects/sipclients3/archive/refs/heads/master.tar.gz

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

  3) Or put the venv's bin on PATH permanently in ~/.bashrc / ~/.zshrc:

         export PATH="$BIN:\$PATH"

================================================================================
EOF
