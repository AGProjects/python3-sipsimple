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

script_name="$(basename "$0")"

usage() {
    cat <<EOF
Usage: ${script_name} [--version VERSION] [--help]

Download pjsip + ZRTPCPP, extract, and apply the patch series.

Options:
    --version VERSION   pjsip version to build (default: 2.17).
                        Supported: 2.17, 2.12. Also accepted as
                        --version=VERSION.
    -h, --help          Show this help and exit.

Version can also be set via:
    PJSIP_VERSION=2.12 ${script_name}
    ${script_name} 2.12               # legacy positional form
    ${script_name} --version=2.12     # fall back to the legacy series

Precedence: --version flag > PJSIP_VERSION env var > positional arg > default.
EOF
}

# Argument parser. Collect --version/--version=X/-v X; everything else
# (including a bare positional) is kept for backward compat.
arg_version=""
positional=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            if [ -z "${2:-}" ]; then
                echo "Error: --version requires a value (2.17 or 2.12)." >&2
                exit 2
            fi
            arg_version="$2"
            shift 2
            ;;
        --version=*)
            arg_version="${1#--version=}"
            shift
            ;;
        -v)
            if [ -z "${2:-}" ]; then
                echo "Error: -v requires a value (2.17 or 2.12)." >&2
                exit 2
            fi
            arg_version="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Error: unknown option '$1'. Run with --help." >&2
            exit 2
            ;;
        *)
            if [ -z "${positional}" ]; then
                positional="$1"
                shift
            else
                echo "Error: unexpected extra argument '$1'." >&2
                exit 2
            fi
            ;;
    esac
done

cd deps

# Version selection precedence:
#   1. --version flag (arg_version)
#   2. PJSIP_VERSION env var
#   3. positional argument (legacy)
#   4. default = 2.17 (the migration target; 2.12 is the legacy fallback)
# Allowed: 2.17 (default, patches/2.17/) and 2.12 (legacy, patches/).
PJSIP_VERSION="${arg_version:-${PJSIP_VERSION:-${positional:-2.17}}}"

case "${PJSIP_VERSION}" in
    2.12)
        # Legacy patch series; lives at deps/patches/[0-9][0-9]_*.patch.
        patches_dir="patches"
        ;;
    2.17)
        # Default series, lives at deps/patches/2.17/.
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
# 2.17 (default) -> deps/patches/2.17/[0-9][0-9]_*.patch
#   Rebased subset; see PJSIP_217_MIGRATION.md.
# 2.12 (legacy)  -> deps/patches/[0-9][0-9]_*.patch
#   01..12 are the pjsip 2.12 functional patches (split out from the
#   old monolith). 13..30 are the auxiliary fixes (zsrtp, tls log, vpx,
#   mac audio, ffmpeg, srtp UAF, AEAD transport, etc).
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

# Prefer GNU patch (gpatch on macOS via brew/macports) over BSD patch.
# BSD patch silently rejects some valid unified-diff hunks that GNU
# patch applies fine (see e.g. 02_zsrtp_link.patch's build.mak.in hunk
# during the 2.17 rebase work).
#
# Falling back to BSD patch is NOT safe: it produces rejects on hunks that
# are perfectly valid (e.g. 31_stream_transport_grp_lock_uaf.patch), which
# looks exactly like a stale patch series and sends you hunting for a
# non-existent rebase problem. Fail loudly instead.
PATCH_CMD=""
for _gp in gpatch /opt/homebrew/bin/gpatch /opt/local/bin/gpatch; do
	if command -v "${_gp}" >/dev/null 2>&1; then
		PATCH_CMD="${_gp}"
		break
	fi
done
unset _gp

if [ -z "${PATCH_CMD}" ]; then
	# No gpatch: accept plain 'patch' only when it really is GNU patch
	# (normal on Linux, never on macOS where /usr/bin/patch is BSD).
	if patch --version 2>/dev/null | head -1 | grep -qi "GNU patch"; then
		PATCH_CMD="patch"
	else
		echo "Error: GNU patch not found."                                  >&2
		echo "       /usr/bin/patch on macOS is BSD patch, which rejects"   >&2
		echo "       hunks in this series that GNU patch applies cleanly."  >&2
		echo "       Install it, then re-run:"                              >&2
		echo "           brew install gpatch"                               >&2
		echo "       or  sudo port install gpatch"                          >&2
		exit 1
	fi
fi
echo "Using ${PATCH_CMD} to apply patches."

for p in "${patches[@]}";
do
	# Skip patches that contain no diff hunks (no '---' header).
	# Used to reserve a slot in the numbered series for changes that
	# are implemented elsewhere.
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
	# -s: silent — suppress per-hunk "succeeded at ..." chatter. Errors
	#     and rejects are still printed.
	#
	# gpatch exit codes:
	#   0 = clean apply
	#   1 = some hunks REJECTED (still applied the rest)
	#   2 = serious trouble (couldn't open file etc)
	# Any non-zero halts the build — a reject means the patch series is
	# stale and silently shipping a half-applied tree leads to confusing
	# downstream failures.
	set +e
	"${PATCH_CMD}" -l -s -p0 <"${p}"
	patch_rc=$?
	set -e
	if [ "${patch_rc}" -ne 0 ]; then
		echo "ERROR: patch ${p} failed with exit ${patch_rc}" >&2
		echo "       Inspect deps/pjsip/**/*.rej and fix the patch." >&2
		exit "${patch_rc}"
	fi
done

# setup_pjsip.py reads pjsip/base_rev to embed PJ_SVN_REVISION into the
# compiled extension. In the 2.12 series this file is written by patch
# 01_build_system.patch; for 2.17 patch 01 hasn't been ported yet, so
# write it here unconditionally so both paths produce the same artifact.
# Value is the version with the dot stripped (2.12 -> "212", 2.17 -> "217").
base_rev_value="${PJSIP_VERSION//./}"
echo "${base_rev_value}" > ./pjsip/base_rev
echo "Wrote pjsip/base_rev = ${base_rev_value}"

# All other 2.17 build/link wiring is handled by patches under
# deps/patches/2.17/ (see 02_zsrtp_link.patch and friends).
