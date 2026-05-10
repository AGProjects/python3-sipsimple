#!/bin/bash
# C/build deps needed by PJSIP and the sipsimple Cython extensions.
# Mirrors the apt list at the top of get_dependencies.sh, plus build tools.

set -e

echo "Installing build-time C dependencies..."

sudo apt-get install -y \
    build-essential pkg-config \
    dh-python python3-all-dev cython3 \
    libasound2-dev libssl-dev libsqlite3-dev \
    libv4l-dev libavcodec-dev libavformat-dev libavutil-dev libswscale-dev \
    libopencore-amrnb-dev libopencore-amrwb-dev \
    libx264-dev libvpx-dev libopus-dev \
    libfdk-aac-dev \
    uuid-dev \
    devscripts debhelper

if [ $? -ne 0 ]; then
    echo
    echo "Failed to install all C dependencies"
    echo
    exit 1
fi
