#!/bin/bash
# Build python3-sipsimple from the local checkout (the directory this script
# lives in IS the python3-sipsimple repo). No tarball download.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -f "$SRC_DIR/setup.py" ] || [ ! -f "$SRC_DIR/setup_pjsip.py" ]; then
    echo
    echo "Expected setup.py and setup_pjsip.py in $SRC_DIR."
    echo "Run this from inside the python3-sipsimple/mac directory."
    echo
    exit 1
fi

source "$SCRIPT_DIR/activate_venv.sh"

cd "$SRC_DIR"

echo "Installing SIP SIMPLE SDK from $SRC_DIR ..."

# Re-running needs a clean deps tree; get_dependencies.sh fails otherwise.
rm -rf deps/pjsip deps/ZRTPCPP deps/pjproject-* 2>/dev/null || true

chmod +x ./get_dependencies*
./get_dependencies.sh 2.12

if [ $? -ne 0 ]; then
    echo
    echo "Failed to install all SIP SIMPLE SDK dependencies"
    echo
    exit 1
fi

# Make sure the build can find MacPorts headers/libs in this shell.
export CFLAGS="-I/opt/local/include"
export LDFLAGS="-L/opt/local/lib"
export PKG_CONFIG_PATH="/opt/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

pip3 install --no-build-isolation .

if [ $? -ne 0 ]; then
    echo
    echo "Failed to build SIP SIMPLE SDK"
    echo
    exit 1
fi

# Resolve the venv root and the python3 site-packages dir for the post-install
# message. VIRTUAL_ENV is set by activate_venv.sh sourcing the venv's activate.
VENV="${VIRTUAL_ENV:-}"
PVER=$(python3 -c "import sys; print('%d.%d' % sys.version_info[:2])")
SITE="$VENV/lib/python$PVER/site-packages"

cat <<EOF

================================================================================
python3-sipsimple installed.

  Package:        $SITE/sipsimple/
  Metadata:       $SITE/python3_sipsimple-*.dist-info/
  Virtualenv:     $VENV
  Scripts/bin:    $VENV/bin/

To use the SDK and (after running ./05-install_sipclients.sh) the sip-* CLI
tools, activate the venv in any shell:

    source $SCRIPT_DIR/activate_venv.sh

Then python, pip, and sip-register3 / sip-session3 / etc. all resolve out of
the venv. To leave the venv: \`deactivate\`.

Or call them directly without activating, e.g.:

    $VENV/bin/python -c "import sipsimple; print(sipsimple.__version__)"
    $VENV/bin/sip-register3 ...      # once 05 is run

If you want the bin/ on PATH permanently, add this to ~/.zshrc or ~/.bash_profile:

    export PATH="$VENV/bin:\$PATH"

================================================================================
EOF
