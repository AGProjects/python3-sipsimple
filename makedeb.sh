#!/bin/bash
if [ -f dist ]; then
    rm -r dist
fi

chmod +x get_dependencies.sh
./get_dependencies.sh

sudo apt install -y equivs devscripts cython3 python3-setuptools
sudo mk-build-deps --install --root-cmd sudo --remove debian/control

chmod +x deps/pjsip/configure
chmod +x deps/pjsip/aconfigure

python3 setup.py sdist

cd dist
tar zxvf *.tar.gz

cd python3-sipsimple-?.?.?

debuild --no-sign

cd ..

ls
