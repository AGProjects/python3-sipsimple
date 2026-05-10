#!/bin/bash
# Linux build prerequisites for python3-sipsimple.
# Verifies a usable Python 3 and that we can call apt (Debian/Ubuntu).

set -e

if ! command -v python3 >/dev/null; then
    echo
    echo "python3 not found. Install your distro's python3 package first."
    echo
    exit 1
fi

env python3 -V | grep -E "3\.(9|10|11|12|13)" >/dev/null
if [ $? -ne 0 ]; then
    echo
    echo "Python 3.9, 3.10, 3.11, 3.12 or 3.13 is required."
    echo "  detected: $(python3 -V)"
    echo
    exit 1
fi

if ! command -v apt-get >/dev/null; then
    echo
    echo "These scripts assume a Debian/Ubuntu host (apt-get not found)."
    echo "On other distros, install the equivalent of the apt list in"
    echo "02-install-c-deps.sh by hand and skip step 02."
    echo
    exit 1
fi

# python3-venv is sometimes a separate package on Debian/Ubuntu.
sudo apt-get update
sudo apt-get install -y python3 python3-venv python3-pip
