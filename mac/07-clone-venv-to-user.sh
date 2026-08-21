#!/bin/bash
# Clone an already-built sipsimple virtualenv to another user account on the
# SAME Mac, without rebuilding PJSIP or the _core extension.
#
# Why a plain copy is not enough: a virtualenv hardcodes its own absolute
# path in pyvenv.cfg and in every script under bin/ (the VIRTUAL_ENV
# assignment in activate*, and the #! shebang of pip, sip-register3,
# sip-session3, ...). Under a different username that path no longer exists,
# so the copied venv's scripts fail with "bad interpreter". This script
# copies the tree and rewrites those references.
#
# What is NOT copied, because it is machine-wide and already shared:
#   - the base Python (the venv only symlinks it)
#   - MacPorts libraries under /opt/local (gnutls, ffmpeg, opus, vpx, x264,
#     bcg729, ...) which _core.so links by absolute path
# The compiled extension is copied as-is: same machine, same architecture,
# same Python minor version, so it loads unchanged.
#
# Usage:
#   sudo ./07-clone-venv-to-user.sh <target-user> [dest-venv-path]
#
#   sudo ./07-clone-venv-to-user.sh bob
#       -> /Users/bob/work/<same-venv-name>
#   sudo ./07-clone-venv-to-user.sh bob /Users/bob/envs/sipsimple
#       -> that exact path
#
# Options:
#   -s, --source PATH   venv to clone (default: $VIRTUAL_ENV, else the one
#                       activate_venv.sh would pick for this Python)
#   -f, --force         overwrite the destination if it already exists
#   -n, --dry-run       show what would happen, change nothing
#   -h, --help          this help

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

src=""
force=0
dry=0
target_user=""
dest=""

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--source)  src="${2:-}"; [ -n "$src" ] || { echo "Error: --source needs a value." >&2; exit 2; }; shift 2 ;;
        --source=*)   src="${1#--source=}"; shift ;;
        -f|--force)   force=1; shift ;;
        -n|--dry-run) dry=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           echo "Error: unknown option '$1'. Run with --help." >&2; exit 2 ;;
        *)
            if   [ -z "$target_user" ]; then target_user="$1"
            elif [ -z "$dest" ];        then dest="$1"
            else echo "Error: unexpected extra argument '$1'." >&2; exit 2
            fi
            shift ;;
    esac
done

if [ -z "$target_user" ]; then
    echo "Error: target user is required." >&2
    echo "Usage: $(basename "$0") <target-user> [dest-venv-path]" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Resolve the source venv
# ---------------------------------------------------------------------------
if [ -z "$src" ]; then
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        src="$VIRTUAL_ENV"
    else
        arch=$(python3 -c "import platform; print(platform.processor())")
        pver=$(python3 -c "import sys; print('%d.%d' % sys.version_info[:2])")
        src="${SUDO_USER:+/Users/$SUDO_USER}"
        src="${src:-$HOME}/work/sipsimple-python-$pver-$arch-env"
    fi
fi
src="${src%/}"

if [ ! -f "$src/bin/activate" ] || [ ! -f "$src/pyvenv.cfg" ]; then
    echo "Error: '$src' does not look like a virtualenv (no bin/activate + pyvenv.cfg)." >&2
    echo "       Pass the right one with --source PATH." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the destination
# ---------------------------------------------------------------------------
if ! id "$target_user" >/dev/null 2>&1; then
    echo "Error: no such user '$target_user' on this Mac." >&2
    exit 1
fi

target_home=$(dscl . -read "/Users/$target_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
if [ -z "$target_home" ] || [ ! -d "$target_home" ]; then
    echo "Error: could not resolve home directory for '$target_user'." >&2
    exit 1
fi

dest="${dest:-$target_home/work/$(basename "$src")}"
dest="${dest%/}"

if [ "$src" = "$dest" ]; then
    echo "Error: source and destination are the same path." >&2
    exit 1
fi

# A venv script's #! line is capped at 127 bytes by the kernel.
if [ ${#dest} -gt 100 ]; then
    echo "Warning: destination path is ${#dest} characters."                >&2
    echo "         Shebangs are limited to 127 bytes; '$dest/bin/python3'"  >&2
    echo "         may be too long. Consider a shorter destination."        >&2
fi

if [ -e "$dest" ]; then
    if [ "$force" -eq 1 ]; then
        echo "Destination exists, --force given: removing $dest"
        [ "$dry" -eq 1 ] || rm -rf "$dest"
    else
        echo "Error: destination '$dest' already exists (use --force to replace)." >&2
        exit 1
    fi
fi

target_group=$(id -gn "$target_user")

echo "Source venv : $src"
echo "Destination : $dest"
echo "Owner       : $target_user:$target_group"
echo

if [ "$dry" -eq 1 ]; then
    echo "[dry-run] would copy, chown, then rewrite '$src' -> '$dest' in:"
    grep -rIl -- "$src" "$src" 2>/dev/null | sed "s|^$src|  |"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: run this with sudo — it must read another user's home and chown the copy." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Copy. ditto is the macOS-native copy: preserves symlinks (bin/python ->
# the framework Python), permissions, ACLs and extended attributes, and
# leaves code signatures on the copied .so files intact.
# ---------------------------------------------------------------------------
echo "Copying tree ..."
mkdir -p "$(dirname "$dest")"
ditto "$src" "$dest"

echo "Setting ownership ..."
chown -R "$target_user:$target_group" "$dest"
chown "$target_user:$target_group" "$(dirname "$dest")" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Rewrite the hardcoded venv path. Only text files are touched (-I skips
# binaries), so no .so or .dylib is modified and no signature is broken.
# Writing via `cat >` keeps each file's existing inode, mode and owner.
# ---------------------------------------------------------------------------
echo "Rewriting venv path references ..."
count=0
while IFS= read -r f; do
    tmp=$(mktemp)
    LC_ALL=C sed "s|${src}|${dest}|g" "$f" > "$tmp"
    cat "$tmp" > "$f"
    rm -f "$tmp"
    echo "  ${f#$dest/}"
    count=$((count + 1))
done < <(grep -rIl -- "$src" "$dest" 2>/dev/null)
echo "  ($count file(s) rewritten)"

# Stale bytecode caches record the old source paths. They are only used for
# tracebacks, but dropping them keeps things tidy and costs nothing.
find "$dest" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# Verify as the target user
# ---------------------------------------------------------------------------
echo
echo "Verifying as $target_user ..."
if sudo -u "$target_user" "$dest/bin/python3" -c \
        'import sipsimple, sipsimple.core._core as c; print("  sipsimple", sipsimple.__version__); print("  _core    ", c.__file__)'; then
    echo "  import OK"
else
    echo "  WARNING: import failed — see the traceback above." >&2
fi

if [ -x "$dest/bin/sip-register3" ]; then
    if sudo -u "$target_user" "$dest/bin/sip-register3" --help >/dev/null 2>&1; then
        echo "  sip-register3 --help OK"
    else
        echo "  WARNING: sip-register3 --help failed." >&2
    fi
fi

cat <<EOF

================================================================================
Done. $target_user can now use it with:

    source $dest/bin/activate

or call it directly without activating:

    $dest/bin/python3 -c "import sipsimple; print(sipsimple.__version__)"
    $dest/bin/sip-register3 ...

Nothing was rebuilt: the compiled _core.so was copied as-is and still links
the shared MacPorts libraries under /opt/local.

To give that user the source checkout as well (optional — only needed if they
will rebuild or run the numbered scripts):

    sudo ditto "$SCRIPT_DIR/.." "$target_home/work/python3-sipsimple"
    sudo chown -R $target_user:$target_group "$target_home/work/python3-sipsimple"
================================================================================
EOF
