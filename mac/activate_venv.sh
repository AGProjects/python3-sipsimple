#!/bin/bash
arch=`python3 -c "import platform; print(platform.processor())"`
pver=`python3 -c "import sys; print(sys.version[0:3])"`

venv="$HOME/work/sipsimple-python-$pver-$arch-env"

echo "Activating $venv..."

if [[ "$0" = "$BASH_SOURCE" ]]; then
    echo "Needs to be run using source: . activate_venv.sh"

else
    VENVPATH="$venv/bin/activate"
    source "$VENVPATH"
fi
