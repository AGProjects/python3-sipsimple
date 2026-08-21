#!/bin/bash
# Source me, don't run me directly: `. activate_venv.sh`
arch=`python3 -c "import platform; print(platform.processor())"`
pver=`python3 -c "import sys; print('%d.%d' % (sys.version_info[0], sys.version_info[1]))"`

venv="$HOME/work/sipsimple-python-$pver-$arch-env"

echo "Activating $venv..."

if [[ "$0" = "${BASH_SOURCE[0]}" ]]; then
    echo "Needs to be run using source: . activate_venv.sh"
elif [ ! -f "$venv/bin/activate" ]; then
    echo "No environment found at $venv, run 03-install-python-deps.sh first."
else
    source "$venv/bin/activate"
fi
