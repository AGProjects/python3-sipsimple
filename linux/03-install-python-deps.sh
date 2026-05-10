#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$HOME/work" ]; then
    mkdir "$HOME/work"
fi

arch=`uname -m`
pver=`python3 -c "import sys; print('%d.%d' % (sys.version_info[0], sys.version_info[1]))"`

envdir="sipsimple-python-$pver-$arch-env"

if [ ! -d "$HOME/work/$envdir" ]; then
    echo "Creating venv at ~/work/$envdir using $(command -v python3) ..."
    python3 -m venv "$HOME/work/$envdir"
else
    echo "Environment exists in ~/work/$envdir"
fi

source "$SCRIPT_DIR/activate_venv.sh"

# System libs are in /usr by default; no need to override CFLAGS/LDFLAGS unless
# you've installed something custom under /usr/local.

pip install --upgrade pip wheel setuptools
pip install -r "$SCRIPT_DIR/python-requirements.txt"
pip install --no-build-isolation -r "$SCRIPT_DIR/sipsimple-requirements.txt"
