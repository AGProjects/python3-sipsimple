#!/bin/bash

unamestr=$(uname)
if [[ "$unamestr" == 'Linux' ]]; then
sudo apt install python3 dh-python python3-all-dev cython3 libasound2-dev \
python3-dateutil python3-dnspython libssl-dev libv4l-dev libavcodec-dev \
libavformat-dev libopencore-amrnb-dev libopencore-amrwb-dev libavutil-dev \
libswscale-dev libx264-dev libvpx-dev libopus-dev libsqlite3-dev pkg-config \
uuid-dev cython3 cython3-dbg python3-setuptools devscripts debhelper dh-python \
python3-all-dev python3-all-dbg libasound2-dev libssl-dev libsqlite3-dev
fi

cd deps

PJSIP_VERSION="${1:-2.10}"

#
# Update PJSIP 
#
echo "Preparing PJSIP $PJSIP_VERSION sources..."
if [ ! -f $PJSIP_VERSION.tar.gz ]; then
    echo Downloading PJSIP $PJSIP_VERSION...
    wget https://github.com/pjsip/pjproject/archive/$PJSIP_VERSION.tar.gz
    if [ $? -eq 0 ]; then
        echo "PJSIP downloaded"
    else
       echo Fail to download PJSIP
       exit 1
    fi
fi

tar xzf $PJSIP_VERSION.tar.gz

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

patches_dir="patches"

if [ -d patches/$PJSIP_VERSION ];then
    patches_dir=patches/$PJSIP_VERSION
fi

uname -v|grep ARM64 |grep Darwin > /dev/null

if [ $? -eq 0 ]; then
   rm $patches_dir/005_fix_ffmpeg.patch 2> /dev/null
   rm $patches_dir/007_video_support_dshow_mingw.patch 2> /dev/null
   rm $patches_dir/008_support_mingw_w64.patch 2> /dev/null
fi

for p in $patches_dir/0*.patch; do
    echo "Applying patch $p"
    patch -p0 < $p > /dev/null
done

cd - > /dev/null
