==========================================================================
SYNC NOTE — this file exists in two repositories and they are kept
independent on purpose. The copies must stay IDENTICAL:

    blink/build_scripts/ffmpeg/readme.txt
    python3-sipsimple/mac/ffmpeg/readme.txt

Edit one, copy it to the other, and record both. To check:

    diff ~/work/blink/build_scripts/ffmpeg/readme.txt \
         ~/work/python3-sipsimple/mac/ffmpeg/readme.txt
==========================================================================

PJMEDIA can make use of the following FFMPEG development components:

libavutil
libavformat
libavcodec
libavdevice
libswscale

This document describes how to build a strip-down version of ffmpeg with
only the needed components.

The local Portfile in this directory diverges from the upstream MacPorts
ffmpeg port in two ways:

  1. A reduced --enable / --disable feature set (only what pjmedia
     needs).
  2. Explicit --enable-neon / --enable-asm / --cpu=generic for the
     arm64 slice. Without these the libswscale produced by ffmpeg
     4.4.5 on Apple Silicon falls back to the C reference loop —
     each sws_scale call then takes tens of milliseconds and pins
     one P-core at 100% during every video call. Forcing the NEON
     assembly paths brings the per-frame cost back down to
     microseconds.

To verify NEON is in the resulting build:

    /opt/local/bin/ffmpeg -buildconf 2>&1 | grep -E '(--enable-neon|--cpu)'

You should see "--enable-neon", "--enable-asm" and "--cpu=generic" on
arm64 systems. (On Intel you see "--enable-x86asm" instead — that's the
equivalent for x86_64 / i386.)

----------------------------------------------------------------
Installation steps:
----------------------------------------------------------------

sudo mkdir -p /opt/local/ports/multimedia/ffmpeg

#/opt/local/var/macports/sources/rsync.macports.org/macports/release/tarballs/ports/multimedia/ffmpeg/Portfile

# The original Portfile
#sudo cp $(port file ffmpeg) /opt/local/ports/multimedia/ffmpeg

cd /opt/local/ports/multimedia/ffmpeg
Edit Portfile if different then this changed version

# Locally changed Portfile
sudo cp Portfile /opt/local/ports/multimedia/ffmpeg

Add file:///opt/local/ports at the beginning of /opt/local/etc/macports/sources.conf

sudo portindex /opt/local/ports
sudo port sync

# First-time install
sudo port install ffmpeg +universal

# If ffmpeg is ALREADY installed from a previous build and you just
# updated the Portfile in this repo (e.g. the NEON change above), bump
# Portfile's `revision` and re-install. The revision-8 bump in the
# tracked Portfile already covers this — `port upgrade ffmpeg` will
# notice. If `upgrade` says "ffmpeg is already up to date", force it:
sudo port -N uninstall ffmpeg
sudo port install ffmpeg +universal

# Verify the produced dylib is fat AND contains NEON instructions
lipo -archs /opt/local/lib/libswscale.5.dylib
# Expected: x86_64 arm64

# Extract the arm64 slice and disassemble — should show NEON SIMD ops
lipo -thin arm64 /opt/local/lib/libswscale.5.dylib -output /tmp/sws-arm64.dylib
otool -tV /tmp/sws-arm64.dylib | grep -E -m5 '\b(ld1|st1|fadd|smlal|ushll)\b' \
    && echo "OK: NEON instructions present in libswscale.5.dylib arm64 slice"

# Re-stage into Blink.app via the build pipeline:
cd ../../Distribution
../build_scripts/09-copy-ffmpeg.sh

Check build command

To check if the right version has been used:

ffmpeg -buildconf

To restore original port file

sudo rm -rf /opt/local/ports/multimedia/ffmpeg

or edit /opt/local/etc/macports/sources.conf
sudo port sync

