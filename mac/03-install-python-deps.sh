#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$HOME/work" ]; then
    mkdir "$HOME/work"
fi

arch=`python3 -c "import platform; print(platform.processor())"`
pver=`python3 -c "import sys; print('%d.%d' % (sys.version_info[0], sys.version_info[1]))"`

venv="$HOME/work/sipsimple-python-$pver-$arch-env"

# Test for the activate script, not just the directory: a failed creation
# leaves an empty directory behind and every later run would skip creation
# and silently install into the user site-packages instead.
if [ ! -f "$venv/bin/activate" ]; then
    if [ -d "$venv" ]; then
        echo "Incomplete environment in $venv, recreating..."
    else
        echo "Creating venv at $venv using $(command -v python3) ..."
    fi
    python3 -m venv "$venv"
else
    echo "Environment exists in $venv"
fi

source "$SCRIPT_DIR/activate_venv.sh"

# Fail loudly rather than installing into the system/user site-packages
if [ -z "$VIRTUAL_ENV" ]; then
    echo "Virtualenv was not activated, aborting."
    exit 1
fi

export CFLAGS="-I/opt/local/include"
export LDFLAGS="-L/opt/local/lib"

pip install --upgrade pip wheel setuptools
pip install -r "$SCRIPT_DIR/python-requirements.txt"
pip install --no-build-isolation -r "$SCRIPT_DIR/sipsimple-requirements.txt"
