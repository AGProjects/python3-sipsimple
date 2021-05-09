#!/bin/bash

#
# Update PJSIP 
#
cd deps

echo "Preparing PJSIP sources..."
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

if [ -d pjsip ]; then
   rm -r pjsip
fi

mkdir pjsip
mv pjproject*/* ./pjsip/

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
echo "Preparing ZRTP sources..."
mkdir ./pjsip/third_party/zsrtp
cp -r zsrtp/include ./pjsip/third_party/zsrtp/
cp -r zsrtp/srtp    ./pjsip/third_party/zsrtp/
cp -r zsrtp/build   ./pjsip/third_party/build/zsrtp

# Copy new version to third_party/zsrtp/
mkdir ./pjsip/third_party/zsrtp/zrtp
cp -r ZRTPCPP/bnlib ./pjsip/third_party/zsrtp/zrtp/
cp -r ZRTPCPP/common ./pjsip/third_party/zsrtp/zrtp/
cp -r ZRTPCPP/cryptcommon ./pjsip/third_party/zsrtp/zrtp/
cp -r ZRTPCPP/srtp ./pjsip/third_party/zsrtp/zrtp/
cp -r ZRTPCPP/zrtp ./pjsip/third_party/zsrtp/zrtp/
cp ZRTPCPP/COPYING ./pjsip/third_party/zsrtp/zrtp/
cp ZRTPCPP/README.md ./pjsip/third_party/zsrtp/zrtp/

for p in patches/*.patch; do
    echo "Applying patch $p"
    cat $p | patch -p0 > /dev/null
done

cd - > /dev/null

