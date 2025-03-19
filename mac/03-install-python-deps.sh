#!/bin/bash
if [ ! -d ~/work ]; then
    mkdir ~/work 
fi

arch=`python3 -c "import platform; print(platform.processor())"`
pver=`python3 -c "import sys; print('%d.%d' % (sys.version_info[0], sys.version_info[1]))"`

envdir=sipsimple-python-$pver-$arch-env

if [ ! -d ~/work/$envdir ]; then
    mkdir ~/work/$envdir
    virtualenv -p /usr/local/bin/python3 ~/work/$envdir
else
    echo "Environment exists in ~/work/$envdir"
fi

source activate_venv.sh

export CFLAGS="-I/opt/local/include"
export LDFLAGS="-L/opt/local/lib"

pip3 install --upgrade pip
pip3 install -r python-requirements.txt
pip3 install -r sipsimple-requirements.txt
