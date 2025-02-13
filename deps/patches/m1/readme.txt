Compiling on Apple Apple Silicon processor
------------------------------------------

1. aconfigure needs to be modified (the one from pjsip 2.11 worked) for webrtc
echo canceller to build, without the Intel sse2 instructions.

2. FFMPEG related patches 001 and 005 don't work anymore.  This is an
overview of the changes made by the large patch 001_pjsip_210.patch

cp -r ../pjsip/third_party/zsrtp third_party/
cp -r ../pjsip/third_party/build/zsrtp third_party/build/
cp ../pjsip/aconfigure aconfigure
cp ../pjsip/aconfigure.ac aconfigure.ac
cp ../pjsip/base_rev base_rev
cp ../pjsip/pjsip/src/pjsip/sip_transport.c pjsip/src/pjsip/
cp ../pjsip/pjsip/src/pjsip/sip_transport_tls.c pjsip/src/pjsip/
cp ../pjsip/pjlib/src/pj/os_core_unix.c pjlib/src/pj/os_core_unix.c
cp ../pjsip/pjsip/include/pjsip/sip_msg.h pjsip/include/pjsip/sip_msg.h
cp ../pjsip/pjsip/include/pjsip-simple/evsub.h pjsip/include/pjsip-simple/evsub.h
cp ../pjsip/pjsip/src/pjsip/sip_msg.c pjsip/src/pjsip/sip_msg.c
cp ../pjsip/pjsip/src/pjsip-simple/evsub.c pjsip/src/pjsip-simple/evsub.c
cp ../pjsip/pjsip/src/pjsip-simple/evsub_msg.c pjsip/src/pjsip-simple/evsub_msg.c
cp ../pjsip/pjsip/src/pjsip-ua/sip_inv.c pjsip/src/pjsip-ua/sip_inv.c
cp ../pjsip/pjnath/include/pjnath/ice_strans.h pjnath/include/pjnath/ice_strans.h
cp ../pjsip/pjnath/src/pjnath/ice_strans.c pjnath/src/pjnath/ice_strans.c
cp ../pjsip/third_party/build/os-darwinos.mak third_party/build/os-darwinos.mak
cp ../pjsip/third_party/build/os-linux.mak third_party/build/os-linux.mak
cp ../pjsip/third_party/build/os-win32.mak third_party/build/os-win32.mak
cp ../pjsip/pjlib/src/pj/ssl_sock_ossl.c pjlib/src/pj/ssl_sock_ossl.c 
cp ~/config_site.h pjlib/include/pj/config_site.h
cp ~/config_auto.h pjmedia/include/pjmedia/config_auto.h
cp ../pjsip/pjmedia/build/Makefile pjmedia/build/Makefile
cp ../pjsip/pjmedia/include/pjmedia/audiodev.h pjmedia/include/pjmedia/audiodev.h
cp ../pjsip/pjmedia/include/pjmedia/event.h pjmedia/include/pjmedia/event.h
cp ../pjsip/pjmedia/include/pjmedia/format.h pjmedia/include/pjmedia/format.h
cp ../pjsip/pjmedia/include/pjmedia/mixer_port.h pjmedia/include/pjmedia/mixer_port.h
cp ../pjsip/pjmedia/include/pjmedia/rtcp.h pjmedia/include/pjmedia/rtcp.h
cp ../pjsip/pjmedia/include/pjmedia/signatures.h pjmedia/include/pjmedia/signatures.h
cp ../pjsip/pjmedia/include/pjmedia/sound_port.h pjmedia/include/pjmedia/sound_port.h
cp ../pjsip/pjmedia/include/pjmedia/transport_ice.h pjmedia/include/pjmedia/transport_ice.h
cp ../pjsip/pjmedia/include/pjmedia/transport_zrtp.h pjmedia/include/pjmedia/transport_zrtp.h
cp ../pjsip/pjmedia/include/pjmedia/vid_stream.h pjmedia/include/pjmedia/vid_stream.h
cp ../pjsip/pjmedia/include/pjmedia-audiodev/audiodev_imp.h pjmedia/include/pjmedia-audiodev/audiodev_imp.h
cp ../pjsip/pjmedia/include/pjmedia.h pjmedia/include/pjmedia.h
cp ../pjsip/pjmedia/include/pjmedia-videodev/fb_dev.h pjmedia/include/pjmedia-videodev/fb_dev.h
cp ../pjsip/pjmedia/include/pjmedia_videodev.h pjmedia/include/pjmedia_videodev.h
cp ../pjsip/pjmedia/src/pjmedia-audiodev/audiodev.c pjmedia/src/pjmedia-audiodev/audiodev.c
cp ../pjsip/pjmedia/src/pjmedia-audiodev/alsa_dev.c pjmedia/src/pjmedia-audiodev/alsa_dev.c
cp ../pjsip/pjmedia/src/pjmedia-audiodev/coreaudio_dev.m pjmedia/src/pjmedia-audiodev/coreaudio_dev.m
cp ../pjsip/pjmedia/src/pjmedia-audiodev/wmme_dev.c pjmedia/src/pjmedia-audiodev/wmme_dev.c
cp ../pjsip/pjmedia/src/pjmedia/audiodev.c pjmedia/src/pjmedia/audiodev.c
cp ../pjsip/pjmedia/src/pjmedia/converter.c pjmedia/src/pjmedia/converter.c
cp ../pjsip/pjmedia/src/pjmedia/echo_common.c pjmedia/src/pjmedia/echo_common.c
cp ../pjsip/pjmedia/src/pjmedia/echo_webrtc_aec.c pjmedia/src/pjmedia/echo_webrtc_aec.c
cp ../pjsip/pjmedia/src/pjmedia/endpoint.c pjmedia/src/pjmedia/endpoint.c
cp ../pjsip/pjmedia/src/pjmedia/format.c pjmedia/src/pjmedia/format.c
cp ../pjsip/pjmedia/src/pjmedia/mixer_port.c pjmedia/src/pjmedia/mixer_port.c
cp ../pjsip/pjmedia/src/pjmedia/rtcp.c pjmedia/src/pjmedia/rtcp.c
cp ../pjsip/pjmedia/src/pjmedia/sound_port.c pjmedia/src/pjmedia/sound_port.c
cp ../pjsip/pjmedia/src/pjmedia/transport_ice.c pjmedia/src/pjmedia/transport_ice.c
cp ../pjsip/pjmedia/src/pjmedia/transport_zrtp.c pjmedia/src/pjmedia/transport_zrtp.c
cp ../pjsip/pjmedia/src/pjmedia/vid_stream.c pjmedia/src/pjmedia/vid_stream.c
cp ../pjsip/pjmedia/src/pjmedia/vid_tee.c pjmedia/src/pjmedia/vid_tee.c
cp ../pjsip/pjmedia/src/pjmedia-codec/opus.c pjmedia/src/pjmedia-codec/opus.c
cp ../pjsip/pjmedia/src/pjmedia-codec/vpx.c pjmedia/src/pjmedia-codec/vpx.c
cp ../pjsip/pjmedia/src/pjmedia-videodev/avf_dev.m pjmedia/src/pjmedia-videodev/avf_dev.m
cp ../pjsip/pjmedia/src/pjmedia-videodev/dshow_dev.c pjmedia/src/pjmedia-videodev/dshow_dev.c
cp ../pjsip/pjmedia/src/pjmedia-videodev/dshow_filter.cpp pjmedia/src/pjmedia-videodev/dshow_filter.cpp
cp ../pjsip/pjmedia/src/pjmedia-videodev/fb_dev.c pjmedia/src/pjmedia-videodev/fb_dev.c
cp ../pjsip/pjmedia/src/pjmedia-videodev/null_dev.c pjmedia/src/pjmedia-videodev/null_dev.c
cp ../pjsip/pjmedia/src/pjmedia-videodev/videodev.c pjmedia/src/pjmedia-videodev/videodev.c

# bad stuff removed from new patch in M1 folder
#cp ../pjsip/pjmedia/src/pjmedia/ffmpeg_util.h pjmedia/src/pjmedia/ffmpeg_util.h
#cp ../pjsip/pjmedia/src/pjmedia-codec/ffmpeg_vid_codecs.c pjmedia/src/pjmedia-codec/ffmpeg_vid_codecs.c
#cp ../pjsip/pjmedia/src/pjmedia/ffmpeg_util.c pjmedia/src/pjmedia/ffmpeg_util.c
#cp ../pjsip/pjmedia/src/pjmedia-videodev/ffmpeg_dev.c pjmedia/src/pjmedia-videodev/ffmpeg_dev.c

With the new 001 patch, and removing 005 patch, pjsip 2.10 was built manually on M1:

export CFLAGS="-arch arm64 -mmacosx-version-min=10.11 -I/opt/local/include"
export LDFLAGS="-arch arm64 -mmacosx-version-min=10.11 -L/opt/local/lib -headerpad_max_install_names"
./configure --host=arm-apple-darwin --disable-openh264 --disable-l16-codec \
--disable-g7221-codec --disable-sdl --disable-ilbc-codec --disable-speex-codec \
--disable-gsm-codec --disable-speex-aec
make
