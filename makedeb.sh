#!/bin/bash
if [ -f dist ]; then
    rm -r dist
fi

./get_dependencies.sh

sudo apt install equivs
sudo mk-build-deps --install debian/control

chmod +x deps/pjsip/configure
chmod +x deps/pjsip/aconfigure

python3 setup.py sdist

cd dist
tar zxvf *.tar.gz

cd python3-sipsimple-?.?.?

debuild --no-sign

cd ..

ls
