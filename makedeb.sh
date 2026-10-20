#!/bin/bash
set -e

distro="${1:-}"
mode="${2:-}"

# When running a 32-bit (armhf) userland on a 64-bit kernel (e.g. Raspberry Pi),
# uname -m reports aarch64 and pjsip/webrtc misdetect the target architecture,
# enabling AArch64-only NEON intrinsics that fail to compile with armhf gcc.
# Prefix the build with setarch linux32 so uname -m reports armv7l.
SETARCH=""
if [ "$(dpkg --print-architecture)" = "armhf" ] && [ "$(uname -m)" = "aarch64" ]; then
    SETARCH="setarch linux32"
    echo "Detected armhf userland on 64-bit kernel: building with '$SETARCH'"
fi

# rebuild mode: reuse the extracted build tree and compiled binaries from a
# previous run; skips clean (-nc) and builds binary packages only (-b)
if [ "$mode" = "rebuild" ]; then
    cd dist/*/
    if [ -n "$distro" ] && [ "$distro" != "sid" ]; then
        sed -i "s/) unstable/$distro) $distro/" debian/changelog
        head -1 debian/changelog
    fi
    $SETARCH debuild --no-sign -nc -b
    exit 0
fi

# Remove stale build artifacts (may be configured for the wrong architecture)
rm -rf dist build

bash get_dependencies.sh 2.17

sudo apt install -y equivs devscripts cython3 python3-setuptools

chmod +x deps/pjsip/configure
chmod +x deps/pjsip/aconfigure

if [ -f setup.py ]; then
    python3 setup.py sdist
else
    python3 -m build --sdist
fi

cd dist
tar zxf *.tar.gz
cd */

# add distro suffix to the changelog version (like autopackager does),
# only in the extracted build tree - never in the source repo
if [ -n "$distro" ] && [ "$distro" != "sid" ]; then
    sed -i "s/) unstable/$distro) $distro/" debian/changelog
    head -1 debian/changelog
fi

# Optional build-deps: setup_pjsip.py builds without them (G.729, Linux screen
# capture). Drop the ones this distro does not have, only in the build tree.
for dep in libbcg729-dev libpipewire-0.3-dev; do
    if ! apt-cache policy "$dep" 2>/dev/null | grep -q 'Candidate: [0-9]'; then
        echo "Optional build-dep $dep not available, building without it"
        sed -i "/^ *$dep,\?\$/d" debian/control
    fi
done

sudo mk-build-deps --install --root-cmd sudo --remove debian/control
rm -f python3-sipsimple-build-deps_*

$SETARCH debuild --no-sign
