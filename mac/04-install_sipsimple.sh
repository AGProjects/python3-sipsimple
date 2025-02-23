#!/bin/bash

version="5.2.3-mac2"
wget https://github.com/AGProjects/python3-sipsimple/archive/refs/tags/$version.tar.gz

tar zxvf $version.tar.gz 
rm $version.tar.gz 

source activate_venv.sh

cd python3-sipsimple-$version

echo "Installing SIP Simple SDK..."

chmod +x ./get_dependencies*
./get_dependencies.sh 2.11

if [ $? -ne 0 ]; then
    echo
    echo "Failed to install all SIP SIMPLE SDK dependencies"
    echo
    exit 1
fi

pip3 install .
if [ $? -ne 0 ]; then
    echo
    echo "Failed to build SIP SIMPLE SDK"
    echo
    cd
    exit 1
fi
