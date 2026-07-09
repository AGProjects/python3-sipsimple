#!/bin/bash

# When running a 32-bit (armhf) userland on a 64-bit kernel (e.g. Raspberry Pi),
# uname -m reports aarch64 and pjsip/webrtc misdetect the target architecture,
# enabling AArch64-only NEON intrinsics that fail to compile with armhf gcc.
# Prefix the build with setarch linux32 so uname -m reports armv7l.
SETARCH=""
if [ "$(dpkg --print-architecture)" = "armhf" ] && [ "$(uname -m)" = "aarch64" ]; then
    SETARCH="setarch linux32"
    echo "Detected armhf userland on 64-bit kernel: building with '$SETARCH'"
fi

# Remove stale build artifacts (may be configured for the wrong architecture)
rm -rf dist build

chmod +x get_dependencies.sh
./get_dependencies.sh

sudo apt install -y equivs devscripts cython3 python3-setuptools
sudo mk-build-deps --install --root-cmd sudo --remove debian/control

chmod +x deps/pjsip/configure
chmod +x deps/pjsip/aconfigure

python3 setup.py sdist

cd dist
tar zxvf *.tar.gz

cd python3-sipsimple-?.?.?

$SETARCH debuild --no-sign

cd ..

ls
