#!/bin/bash
# Build python3-sipsimple from the local checkout (the directory this script
# lives in IS the python3-sipsimple repo). No tarball download.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# PJSIP version selection. Never interactive: the version comes from the
# command line, then the environment, then the default.
#
#   ./04-install_sipsimple.sh                    -> 2.17 (default)
#   ./04-install_sipsimple.sh 2.12               -> legacy series
#   ./04-install_sipsimple.sh --version 2.12
#   ./04-install_sipsimple.sh --version=2.12
#   PJSIP_VERSION=2.12 ./04-install_sipsimple.sh
#
# See PJSIP_217_MIGRATION.md for the difference between the two patch sets
# (deps/patches/ for 2.12, deps/patches/2.17/ for 2.17).
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [--version VERSION] [--help]

Build and install python3-sipsimple against a given PJSIP version.

Options:
  --version VERSION   PJSIP version to build against: 2.17 (default) or 2.12.
                      Also accepted as --version=VERSION, -v VERSION, or as a
                      bare positional argument.
  -h, --help          Show this help and exit.

PJSIP_VERSION in the environment is used when no argument is given.
EOF
}

arg_version=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version|-v)
            if [ -z "${2:-}" ]; then
                echo "Error: $1 requires a value (2.17 or 2.12)." >&2
                exit 2
            fi
            arg_version="$2"
            shift 2
            ;;
        --version=*)
            arg_version="${1#--version=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Error: unknown option '$1'. Run with --help." >&2
            exit 2
            ;;
        *)
            if [ -n "$arg_version" ]; then
                echo "Error: unexpected extra argument '$1'." >&2
                exit 2
            fi
            arg_version="$1"
            shift
            ;;
    esac
done

PJSIP_VERSION="${arg_version:-${PJSIP_VERSION:-2.17}}"

case "$PJSIP_VERSION" in
    2.17|2.12) ;;
    *)
        echo "Error: unsupported PJSIP version '$PJSIP_VERSION'." >&2
        echo "       Supported values: 2.17 (default), 2.12 (legacy)." >&2
        exit 2
        ;;
esac

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

echo "Building against PJSIP $PJSIP_VERSION."

# Re-running needs a clean deps tree; get_dependencies.sh fails otherwise.
rm -rf deps/pjsip deps/ZRTPCPP deps/pjproject-* 2>/dev/null || true

chmod +x ./get_dependencies*
./get_dependencies.sh --version "$PJSIP_VERSION"

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
# when Python is invoked from this directory (CWD on sys.path). This is a
# build artifact of `build_ext --inplace`, not the installed package, so
# removing it does not touch what is in site-packages.
find sipsimple -name "_core*.so" -print -delete 2>/dev/null || true

# Build BEFORE touching the installed package.
#
# This used to `pip3 uninstall` and then `pip3 install .`, so a build that
# failed -- a Cython error, a compiler error, a missing dependency -- left the
# venv with no SDK at all, and the only way back was to fix the source and get
# a build to succeed. Now the wheel is built first and the installed package is
# only replaced once there is something to replace it with. A failed build
# leaves the previous install exactly as it was.
#
# Note that `set -e` is in effect, so the old `if [ $? -ne 0 ]` check after
# pip could never have run: pip failing aborted the script before reaching it.
# The checks below are written as `if ! cmd; then` so they actually execute.
WHEEL_DIR="$SRC_DIR/dist/wheel-$$"
rm -rf "$WHEEL_DIR"
mkdir -p "$WHEEL_DIR"

echo "Building the wheel (the installed SDK is left alone until this succeeds) ..."
if ! pip3 wheel --no-deps --no-build-isolation --wheel-dir "$WHEEL_DIR" .; then
    echo
    echo "Failed to build SIP SIMPLE SDK."
    echo "The previously installed SDK has NOT been touched:"
    python3 -c 'import sipsimple; print("  still installed:", sipsimple.__version__)' 2>/dev/null \
        || echo "  (no SDK was installed to begin with)"
    echo
    rm -rf "$WHEEL_DIR"
    exit 1
fi

WHEEL="$(ls -1 "$WHEEL_DIR"/python3_sipsimple-*.whl 2>/dev/null | head -n 1)"
if [ -z "$WHEEL" ]; then
    echo
    echo "The build reported success but produced no wheel in $WHEEL_DIR."
    echo "The previously installed SDK has NOT been touched."
    echo
    rm -rf "$WHEEL_DIR"
    exit 1
fi

echo "Installing $(basename "$WHEEL") ..."
if ! pip3 install --force-reinstall --no-deps "$WHEEL"; then
    echo
    echo "Failed to install the freshly built wheel."
    echo "The wheel is kept at $WHEEL so you can retry the install by hand:"
    echo "    pip3 install --force-reinstall --no-deps $WHEEL"
    echo
    exit 1
fi

rm -rf "$WHEEL_DIR"

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
