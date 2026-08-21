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
    echo "Run this from inside the python3-sipsimple/linux directory."
    echo
    exit 1
fi

source "$SCRIPT_DIR/activate_venv.sh"

cd "$SRC_DIR"

echo "Installing SIP SIMPLE SDK from $SRC_DIR ..."

echo "Building against PJSIP $PJSIP_VERSION."

# Re-running needs a clean deps tree; get_dependencies.sh fails otherwise.
rm -rf deps/pjsip deps/ZRTPCPP deps/pjproject-* 2>/dev/null || true

# AUTOINSTALL=0 skips the apt block at the top of get_dependencies.sh
# (we already installed everything via 02-install-c-deps.sh).
chmod +x ./get_dependencies*
AUTOINSTALL=0 PJSIP_VERSION="$PJSIP_VERSION" ./get_dependencies.sh

if [ $? -ne 0 ]; then
    echo
    echo "Failed to install all SIP SIMPLE SDK dependencies"
    echo
    exit 1
fi

pip3 install --no-build-isolation .

if [ $? -ne 0 ]; then
    echo
    echo "Failed to build SIP SIMPLE SDK"
    echo
    exit 1
fi

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

If you want the bin/ on PATH permanently, add this to ~/.bashrc or ~/.zshrc:

    export PATH="$VENV/bin:\$PATH"

================================================================================
EOF
