#!/bin/bash
#
# Install bcg729 (Belledonne G.729) into the MacPorts prefix so that
# setup_pjsip.py picks it up automatically and enables the G.729 codec.
#
# bcg729 is NOT in MacPorts or Homebrew, so we build it from upstream.
#
# Fail-soft semantics:
#   - If anything goes wrong (no network, cmake missing, build error,
#     sudo declined, tag moved, etc.) we print a clear warning and
#     exit 0. The rest of the install (steps 03-05) then proceeds and
#     simply omits G.729 codec support — setup_pjsip.py logs
#     "bcg729 development headers not found; G.729 codec will be
#     disabled." and PJSIP is built without it.
#
# Re-running is safe: if bcg729 is already installed at the target
# prefix, we skip the build entirely.
#
# Knobs (env vars):
#   BCG729_PREFIX   install prefix              (default: /opt/local)
#   BCG729_TAG      git tag to build            (default: 1.1.1)
#   BCG729_REPO     git repo URL                (default: github mirror)
#

set -u

PREFIX="${BCG729_PREFIX:-/opt/local}"
TAG="${BCG729_TAG:-1.1.1}"
REPO="${BCG729_REPO:-https://github.com/BelledonneCommunications/bcg729.git}"
WORK="${TMPDIR:-/tmp}/bcg729-build-$$"

skip() {
    echo
    echo "WARNING: bcg729 install skipped — $*"
    echo "         The SDK will be built without G.729 codec support."
    echo "         Re-run this script after fixing the issue to add G.729 later."
    echo
    rm -rf "$WORK" 2>/dev/null || true
    exit 0
}

fix_install_name() {
    # MacPorts convention: every dylib under /opt/local/lib must have its
    # install_name (LC_ID_DYLIB) set to its own absolute path. bcg729's CMake
    # build defaults to @rpath/libbcg729.0.dylib, which fails dlopen from any
    # consumer that doesn't carry an LC_RPATH for /opt/local/lib — and PJSIP
    # / sipsimple's _core.so don't add one. Patch each concrete dylib so it
    # advertises an absolute path; consumers linked against it from this
    # point forward record the absolute path and dlopen Just Works.
    #
    # On Apple Silicon any LC_ID_DYLIB edit invalidates the ad-hoc signature,
    # so we re-sign immediately afterwards. Errors here are fatal — leaving
    # the dylib half-fixed is worse than skipping the whole install.
    [ "$(uname -s)" = "Darwin" ] || return 0

    command -v otool             >/dev/null 2>&1 || skip "otool not found (install Xcode command line tools: xcode-select --install)"
    command -v install_name_tool >/dev/null 2>&1 || skip "install_name_tool not found (xcode-select --install)"
    command -v codesign          >/dev/null 2>&1 || skip "codesign not found (xcode-select --install)"

    local dylib id fixed_any=0
    for dylib in "$PREFIX"/lib/libbcg729*.dylib; do
        [ -f "$dylib" ] || continue
        [ -L "$dylib" ] && continue          # skip symlinks; we'll patch the real file
        id=$(otool -D "$dylib" 2>/dev/null | tail -n 1 | xargs)
        case "$id" in
            "$dylib")
                # Already absolute and pointing at itself — nothing to do.
                ;;
            @rpath/*|@loader_path/*|@executable_path/*|"")
                echo "  patching install_name on $dylib (was: ${id:-<unset>}) ..."
                sudo install_name_tool -id "$dylib" "$dylib" \
                    || skip "install_name_tool -id failed on $dylib"
                sudo codesign --force --sign - "$dylib" >/dev/null 2>&1 \
                    || skip "codesign --force --sign - failed on $dylib (Apple Silicon requires re-signing)"
                fixed_any=1
                ;;
            /*)
                # Some other absolute path — leave it; the user/distributor
                # may have intentionally set it that way.
                ;;
        esac

        # Verify the fix took.
        local now
        now=$(otool -D "$dylib" 2>/dev/null | tail -n 1 | xargs)
        if [ "$now" != "$dylib" ] && [ "${now#/}" = "$now" ]; then
            # Still not absolute — give up loudly rather than pretending success.
            skip "install_name on $dylib is '$now' after patching; expected '$dylib'"
        fi
    done

    if [ "$fixed_any" = "1" ]; then
        echo "  install_name normalised; any consumer linked against bcg729 from now on"
        echo "  will record the absolute path (no LC_RPATH needed)."
    fi
}

# 0) Already installed? (probe the same files setup_pjsip.py probes)
if [ -f "$PREFIX/include/bcg729/encoder.h" ] && \
   { [ -f "$PREFIX/lib/libbcg729.dylib" ] || \
     [ -f "$PREFIX/lib/libbcg729.a" ]    || \
     [ -f "$PREFIX/lib/libbcg729.so" ]; }; then
    echo "bcg729 already installed at $PREFIX."
    echo "Verifying dylib install_name (macOS only) ..."
    fix_install_name
    echo "bcg729 ready at $PREFIX — setup_pjsip.py will pick it up automatically."
    exit 0
fi

# 1) Tooling
command -v cmake >/dev/null 2>&1 || skip "cmake not found (sudo port install cmake)"
command -v git   >/dev/null 2>&1 || skip "git not found"
command -v sudo  >/dev/null 2>&1 || skip "sudo not found (install needs root for $PREFIX)"

# 2) Fetch
mkdir -p "$WORK" || skip "cannot create $WORK"
cd "$WORK"       || skip "cannot enter $WORK"

echo "Cloning bcg729 $TAG from $REPO ..."
if ! git clone --depth 1 --branch "$TAG" "$REPO" src 2>/dev/null; then
    echo "Tag $TAG not reachable; falling back to default branch ..."
    git clone --depth 1 "$REPO" src || skip "git clone of bcg729 failed (no network?)"
fi

# 3) Configure + build (shared lib; G.729 is a tiny codec, no test suite needed)
cd src || skip "cloned src directory missing"

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"

cmake -B build -S . \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DENABLE_TESTS=NO \
    -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" \
    -DCMAKE_MACOSX_RPATH=OFF \
    >/dev/null || skip "cmake configure failed"

cmake --build build -j"$JOBS" || skip "cmake build failed"

# 4) Install (needs sudo for /opt/local — same pattern as 02-install-c-deps.sh)
echo "Installing bcg729 to $PREFIX (sudo) ..."
sudo cmake --install build || skip "sudo cmake --install failed"

# 5) Verify the files setup_pjsip.py looks for actually landed
if [ ! -f "$PREFIX/include/bcg729/encoder.h" ]; then
    skip "headers not found at $PREFIX/include/bcg729/ after install"
fi
if [ ! -f "$PREFIX/lib/libbcg729.dylib" ] && \
   [ ! -f "$PREFIX/lib/libbcg729.a" ]    && \
   [ ! -f "$PREFIX/lib/libbcg729.so" ]; then
    skip "library not found at $PREFIX/lib/ after install"
fi

# Normalise install_name on macOS so PJSIP / _core.so can dlopen the lib
# without an LC_RPATH (see fix_install_name above). No-op on non-Darwin.
fix_install_name

echo
echo "bcg729 $TAG installed at $PREFIX."
echo "setup_pjsip.py will auto-detect it and enable PJMEDIA_HAS_BCG729=1."
echo

rm -rf "$WORK"
exit 0
