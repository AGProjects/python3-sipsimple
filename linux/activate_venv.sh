#!/bin/bash
# Source me, don't run me directly: `. activate_venv.sh`
arch=`uname -m`
pver=`python3 -c "import sys; print('%d.%d' % (sys.version_info[0], sys.version_info[1]))"`

venv="$HOME/work/sipsimple-python-$pver-$arch-env"

echo "Activating $venv..."

if [[ "$0" = "${BASH_SOURCE[0]}" ]]; then
    echo "Needs to be run using source: . activate_venv.sh"
else
    source "$venv/bin/activate"
fi
