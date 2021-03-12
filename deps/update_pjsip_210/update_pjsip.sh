#!/bin/bash


#
# Revert all non-commited changes
#

echo
echo "Revert uncommitted changes..."
echo

darcs revert -a ../../sipsimple/configuration/
darcs revert -a ../../sipsimple/core/
darcs revert -a ../../deps/pjsip/
darcs revert -a ../../setup_pjsip.py

#
# Update PJSIP 
#
# Get latest stable release from github
if [ ! -f 2.10.tar.gz ]; then
    echo Downloading PJSIP 2.10...
    wget https://github.com/pjsip/pjproject/archive/2.10.tar.gz
    if [ $? -eq 0 ]; then
        echo "PJSIP downloaded"
    else
       echo Fail to download PJSIP
       exit 1
    fi
fi

tar xzf 2.10.tar.gz

echo
echo Copying old files
mkdir old
mv ../pjsip old/
echo Updating pjsip
mv pjproject* ../pjsip

#
# Update ZSRTP
#

# Clone latest version from github
if [ ! -d ZRTPCPP ]; then
    echo Downloading ZRTP...
    git clone https://github.com/wernerd/ZRTPCPP.git
    if [ $? -eq 0 ]; then
        echo "ZRTP downloaded"
        cd ZRTPCPP
        git checkout 6b3cd8e6783642292bad0c21e3e5e5ce45ff3e03
        cd ..
    else
       echo Fail to download ZRTP
       exit 1
    fi
fi

# Copy wrapper from old version to third_party/zsrtp/
echo Copying zsrtp wrapper from old version to third_party/zsrtp/
mkdir ../pjsip/third_party/zsrtp
cp -r old/pjsip/third_party/zsrtp/include ../pjsip/third_party/zsrtp/
cp -r old/pjsip/third_party/zsrtp/srtp ../pjsip/third_party/zsrtp/
cp -r old/pjsip/third_party/build/zsrtp ../pjsip/third_party/build/

# Copy new version to third_party/zsrtp/
echo Copying new version of zrtp to third_party/zsrtp/
mkdir ../pjsip/third_party/zsrtp/zrtp
cp -r ZRTPCPP/bnlib ../pjsip/third_party/zsrtp/zrtp/
cp -r ZRTPCPP/common ../pjsip/third_party/zsrtp/zrtp/
cp -r ZRTPCPP/cryptcommon ../pjsip/third_party/zsrtp/zrtp/
cp -r ZRTPCPP/srtp ../pjsip/third_party/zsrtp/zrtp/
cp -r ZRTPCPP/zrtp ../pjsip/third_party/zsrtp/zrtp/
cp ZRTPCPP/COPYING ../pjsip/third_party/zsrtp/zrtp/
cp ZRTPCPP/README.md ../pjsip/third_party/zsrtp/zrtp/

# Clean update directory
# echo Cleaning update directory
#rm -rf ZRTPCPP

# Clean old directory
echo Cleaning old directory
rm -rf old 

cd .. 

echo Applying pjsip patches 
cat update_pjsip_210/patches/pjsip_210.patch | patch -p0


echo Applying zsrtp patches 
cat update_pjsip_210/patches/zsrtp.patch | patch -p0

cd .. 

echo Applying sipsimple/core patches 
cat deps/update_pjsip_210/patches/sipsimple_core.patch | patch -p0

cd -

echo Done
