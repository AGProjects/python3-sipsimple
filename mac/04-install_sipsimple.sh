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

# PJSIP version selection. If PJSIP_VERSION is already set in the
# environment (e.g. in CI or by an outer script) we honour it without
# prompting. Otherwise, ask interactively. See PJSIP_217_MIGRATION.md
# for the difference between the two patch sets (deps/patches/ for 2.12,
# deps/patches/2.17/ for 2.17).
if [ -z "${PJSIP_VERSION:-}" ]; then
    if [ -t 0 ]; then
        echo
        echo "Which PJSIP version do you want to build against?"
        echo "  A) 2.12   (legacy, fully patched, current production)"
        echo "  B) 2.17   (in-progress migration target)"
        echo
        read -r -p "Choose [A/B] (default A): " _pjsip_choice
        case "${_pjsip_choice:-A}" in
            A|a) PJSIP_VERSION=2.12 ;;
            B|b) PJSIP_VERSION=2.17 ;;
            2.12|2.17) PJSIP_VERSION="$_pjsip_choice" ;;
            *)   echo "Unrecognized choice '$_pjsip_choice' -- defaulting to 2.12."
                 PJSIP_VERSION=2.12 ;;
        esac
        unset _pjsip_choice
    else
        # Non-interactive (stdin not a tty) and no env override: default
        # to 2.12 so unattended re-runs match the current production set.
        PJSIP_VERSION=2.12
    fi
fi
echo "Building against PJSIP $PJSIP_VERSION."

# Re-running needs a clean deps tree; get_dependencies.sh fails otherwise.
rm -rf deps/pjsip deps/ZRTPCPP deps/pjproject-* 2>/dev/null || true

chmod +x ./get_dependencies*
PJSIP_VERSION="$PJSIP_VERSION" ./get_dependencies.sh

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

# Optional codec probe — bcg729 (G.729) is built+installed by 02b-install-bcg729.sh.
# It's not in MacPorts/Homebrew, so just warn (don't fail) if it isn't present;
# setup_pjsip.py will then build PJSIP without G.729 support.
if [ -f "/opt/local/include/bcg729/encoder.h" ] && [ -f "/opt/local/lib/libbcg729.dylib" ]; then
    echo "G.729 codec: bcg729 found at /opt/local — will be built into PJSIP."
else
    echo
    echo "NOTE: bcg729 not found at /opt/local — G.729 codec will be DISABLED."
    echo "      Run '$SCRIPT_DIR/02b-install-bcg729.sh' first if you want G.729."
    echo
fi

# Force a clean rebuild every time this script runs.  Without this:
#   - the stale build/ tree (old pjsip + old _core.so) is reused
#   - pip sees the same version already installed and skips reinstalling
#   - any in-tree _core.so left over from a previous `build_ext --inplace`
#     run will shadow the freshly installed wheel when CWD is on sys.path
#     (the import resolves the source-tree copy first, and it's likely linked
#     against the wrong libavdevice / libavformat ABI by now).
# Wipe everything that could shadow or corrupt the new install.
echo "Cleaning previous build artifacts ..."
rm -rf build/ build_inplace/ python3_sipsimple.egg-info/
# Remove any in-tree compiled extension that would shadow the venv install
# when Python is invoked from this directory (CWD on sys.path).
find sipsimple -name "_core*.so" -print -delete 2>/dev/null || true
pip3 uninstall -y python3-sipsimple >/dev/null 2>&1 || true

pip3 install --force-reinstall --no-deps --no-build-isolation .

if [ $? -ne 0 ]; then
    echo
    echo "Failed to build SIP SIMPLE SDK"
    echo
    exit 1
fi

# Confirm the freshly built extension actually picked up bcg729 (if it was present).
# IMPORTANT: cd out of $SRC_DIR before importing. Otherwise CWD is on sys.path
# and any stray in-tree sipsimple/core/_core*.so (e.g. from `build_ext --inplace`)
# will shadow the freshly installed wheel — we'd verify the wrong .so and likely
# see an unrelated ImportError from a stale ffmpeg/libavdevice ABI mismatch.
echo
echo "Verifying installed _core extension ..."
INSTALLED_SO="$(cd / && python3 -c 'import sipsimple.core._core; print(sipsimple.core._core.__file__)' || true)"
if [ -z "$INSTALLED_SO" ]; then
    echo "  (could not import sipsimple.core._core to verify)"
elif [ ! -f "/opt/local/lib/libbcg729.dylib" ]; then
    echo "  G.729: bcg729 not installed, skipping codec verification."
else
    echo "  extension: $INSTALLED_SO"
    if otool -L "$INSTALLED_SO" 2>/dev/null | grep -qi bcg729; then
        echo "  G.729 codec: verified — _core.so links libbcg729."
    else
        echo "  WARNING: bcg729 was present at build time but _core.so does not link it."
        echo "           Check setup_pjsip.py output above for 'Found bcg729 at ...'."
    fi
fi

# Spin up a throwaway Engine and ask PJSIP what audio + video codecs it actually
# registered. Decode the bytes for a friendlier display. Best-effort: any
# exception here is logged but doesn't fail the install.
echo
# Delegate the live codec enumeration to a standalone script so you can run
# the same check at any time without re-installing — see ./06-show-codecs.sh.
if [ -x "$SCRIPT_DIR/06-show-codecs.sh" ]; then
    "$SCRIPT_DIR/06-show-codecs.sh" || echo "  (codec enumeration failed; install itself was OK)"
else
    echo "  (skipping codec check: $SCRIPT_DIR/06-show-codecs.sh not executable)"
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
