#!/bin/bash
sudo port install darcs yasm x264 gnutls openssl sqlite3 gnutls ffmpeg mpfr libmpc libvpx

pip3 install --user cython==0.29.37 dnspython lxml twisted python-dateutil greenlet zope.interface requests gmpy2 wheel gevent

./get_dependencies.sh 

cd ..
for p in python3-application python3-eventlib python3-gnutls python3-otr python3-msrplib python3-xcaplib; do
    if [ ! -d $p ]; then
       darcs clone http://devel.ag-projects.com/repositories/$p
    fi
    cd $p
    pip3 install --user .
    cd ..
done

cd python3-sipsimple
pip3 install --user .
cd ..

cd sipclients3
pip3 install --user .
cd ..

