#!/bin/bash

#
# Update PJSIP 
#

# Get latest stable release from github
wget --no-check-certificate https://github.com/pjsip/pjproject/archive/2.10.tar.gz
tar xzf 2.10.tar.gz
rm 2.10.tar.gz


echo Copying old files
mkdir old
mv ../pjsip old/
echo Updating pjsip
mv pjproject* ../pjsip



#
# Update ZSRTP
#

# Clone latest version from github
git clone https://github.com/wernerd/ZRTPCPP.git

# Copy wrapper from old version to third_party/zsrtp/
echo Copyng zsrtp wrapper from old version to third_party/zsrtp/
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
echo Cleaning update directory
rm -rf ZRTPCPP

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

