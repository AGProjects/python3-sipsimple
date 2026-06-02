#!/usr/bin/env bash
set -eu -o pipefail

unamestr=$(uname)
#if [[ "$unamestr" == 'Linux' && ${AUTOINSTALL:-1} != 0 ]]; then
#sudo apt install python3 dh-python python3-all-dev cython3 libasound2-dev \
#python3-dateutil python3-dnspython libssl-dev libv4l-dev libavcodec-dev \
#libavformat-dev libopencore-amrnb-dev libopencore-amrwb-dev libavutil-dev \
#libswscale-dev libx264-dev libvpx-dev libopus-dev libbcg729-dev libsqlite3-dev pkg-config \
#uuid-dev cython3 cython3-dbg python3-setuptools devscripts debhelper dh-python \
#python3-all-dev python3-all-dbg libasound2-dev libssl-dev libsqlite3-dev
#fi

cd deps

# Version selection:
#   - PJSIP_VERSION env var wins
#   - $1 (positional) is the legacy interface, still honored
#   - default is 2.17 (the in-progress migration target)
# Allowed: 2.17 (default, patches/2.17/) and 2.12 (legacy, patches/).
PJSIP_VERSION="${PJSIP_VERSION:-${1:-2.17}}"

case "${PJSIP_VERSION}" in
    2.12)
        # Existing patch series; lives at deps/patches/[0-9][0-9]_*.patch.
        patches_dir="patches"
        ;;
    2.17)
        # Rebased subset for 2.17 lives at deps/patches/2.17/.
        # See PJSIP_217_MIGRATION.md at the repo root for the rebase plan.
        patches_dir="patches/2.17"
        if [ ! -d "${patches_dir}" ]; then
            echo "Error: ${patches_dir} does not exist."                   >&2
            echo "       PJSIP 2.17 support requires rebased patches."     >&2
            echo "       See PJSIP_217_MIGRATION.md for the plan."         >&2
            exit 1
        fi
        ;;
    *)
        echo "Error: unsupported PJSIP_VERSION='${PJSIP_VERSION}'."        >&2
        echo "       Supported values: 2.17 (default), 2.12 (legacy)."     >&2
        exit 1
        ;;
esac

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

# Patch series for the selected pjsip version.
# 2.12 (default) -> deps/patches/[0-9][0-9]_*.patch
#   01..12 are the pjsip 2.12 functional patches (split out from the
#   old monolith). 13..30 are the auxiliary fixes (zsrtp, tls log, vpx,
#   mac audio, ffmpeg, srtp UAF, AEAD transport, etc).
# 2.17 (opt-in) -> deps/patches/2.17/[0-9][0-9]_*.patch
#   Rebased subset; see PJSIP_217_MIGRATION.md.
patches=( "${patches_dir}"/[0-9][0-9]_*.patch )

# Skip the FFmpeg-build patch on Apple Silicon — it doesn't apply cleanly there
# (see patches/apple-silicon.txt for background).
if uname -v | grep ARM64 | grep Darwin >/dev/null;
then
	patches_subset=()
	for path in "${patches[@]}";
	do
		case "${path}" in
			"${patches_dir}/17_fix_ffmpeg.patch") ;;
			*) patches_subset+=( "${path}" ) ;;
		esac
	done
	patches=( "${patches_subset[@]}" )
fi

for p in "${patches[@]}";
do
	# Skip patches that contain no diff hunks (no '---' header).
	# Used to reserve a slot in the numbered series for changes that
	# are implemented elsewhere (e.g. 02_zsrtp_link.patch's wiring
	# happens further down in this script directly).
	if ! grep -q '^---' "${p}"; then
		echo "Skipping ${p} (no diff content)"
		continue
	fi
	echo "Applying patch ${p}"
	# -l: ignore whitespace differences when matching context. Needed for
	#     patches whose context spans the unusual single-space "blank"
	#     lines in transport_zrtp.c (lines 893 and 895), which can't be
	#     reliably represented in some editors. Existing strict-match
	#     patches in the series still apply cleanly under -l.
	patch -l -p0 <"${p}"
done

# setup_pjsip.py reads pjsip/base_rev to embed PJ_SVN_REVISION into the
# compiled extension. In the 2.12 series this file is written by patch
# 01_build_system.patch; for 2.17 patch 01 hasn't been ported yet, so
# write it here unconditionally so both paths produce the same artifact.
# Value is the version with the dot stripped (2.12 -> "212", 2.17 -> "217").
base_rev_value="${PJSIP_VERSION//./}"
echo "${base_rev_value}" > ./pjsip/base_rev
echo "Wrote pjsip/base_rev = ${base_rev_value}"

# 2.17 needs libzsrtp built and linked. The 2.12 series gets this via
# patch 01_build_system.patch which hasn't been rebased yet. BSD patch
# on macOS rejected the standalone hunk for reasons unclear, so splice
# in the three pieces directly here. Idempotent: guarded by grep.
if [ "${PJSIP_VERSION}" = "2.17" ]; then
    echo "Wiring zsrtp into pjsip build (2.17 path)..."

    # 1. Get pjsip's third_party build to descend into zsrtp/.
    #    pjsip 2.17 sets OS_NAME := auto in build.mak, so common.mak's
    #    `-include os-$(OS_NAME).mak` picks up third_party/build/os-auto.mak
    #    (generated by configure from os-auto.mak.in), NOT os-darwinos.mak.
    #    So we have to append DIRS += zsrtp to the .in template before
    #    configure runs. configure preserves non-@var@ lines verbatim.
    osauto="pjsip/third_party/build/os-auto.mak.in"
    if ! grep -q '^DIRS += zsrtp' "${osauto}"; then
        echo "DIRS += zsrtp" >> "${osauto}"
        echo "  + appended 'DIRS += zsrtp' to ${osauto}"
    fi

    # 2. Splice libzsrtp linkage into build.mak.in just before
    #    '# Additional flags'. python3 because BSD sed's in-place
    #    quoting differs from GNU and we want one portable code path.
    python3 - <<'PY_EOF'
path = 'pjsip/build.mak.in'
with open(path) as f:
    s = f.read()
if 'libzsrtp' in s:
    print(f"  - {path}: libzsrtp block already present, skipping")
else:
    block = (
        "\n"
        "ifeq (@ac_external_zsrtp@,1)\n"
        "APP_THIRD_PARTY_EXT += -lzsrtp\n"
        "else\n"
        "APP_THIRD_PARTY_LIB_FILES += $(PJ_DIR)/third_party/lib/libzsrtp-$(LIB_SUFFIX)\n"
        "ifeq ($(PJ_SHARED_LIBRARIES),)\n"
        "APP_THIRD_PARTY_LIBS += -lzsrtp-$(TARGET_NAME) -lsqlite3 -lstdc++\n"
        "else\n"
        "APP_THIRD_PARTY_LIBS += -lzsrtp\n"
        "APP_THIRD_PARTY_LIB_FILES += $(PJ_DIR)/third_party/lib/libzsrtp.$(SHLIB_SUFFIX).$(PJ_VERSION_MAJOR) $(PJ_DIR)/third_party/lib/libzsrtp.$(SHLIB_SUFFIX)\n"
        "endif\n"
        "endif\n"
    )
    needle = "# Additional flags"
    if needle not in s:
        raise SystemExit(f"{path}: anchor '{needle}' not found")
    s = s.replace(needle, block + "\n" + needle, 1)
    with open(path, 'w') as f:
        f.write(s)
    print(f"  + spliced libzsrtp block into {path}")
PY_EOF
fi
