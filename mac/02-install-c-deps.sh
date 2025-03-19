#!/bin/bash

# Install C building dependencies
echo "Installing port dependencies..."

sudo port install yasm x264 gnutls openssl sqlite3 ffmpeg mpfr libmpc libvpx wget gmp mpc libuuid

# This will conflict with buildin MacOS
sudo mv /opt/local/include/uuid/uuid.h /opt/local/include/uuid/uuid.h.old

RESULT=$?
if [ $RESULT -ne 0 ]; then
    echo
    echo "Failed to install all C dependencies"
    echo
    exit 1
fi
