
import errno
import itertools
import os
import platform
import re
import shutil
import subprocess
import sys

if sys.platform.startswith('linux'):
    sys_platform = 'linux'
elif sys.platform.startswith('freebsd'):
    sys_platform = 'freebsd'
else:
    sys_platform = sys.platform


# Hack to set environment variables before importing distutils
# modules that will fetch them and set the compiler and linker
# to be used. -Saul

if sys_platform == "darwin":
    min_osx_version = "10.11"
    try:
        osx_sdk_path = subprocess.check_output(["xcodebuild", "-version", "-sdk", "macosx", "Path"]).decode().strip()
    except subprocess.CalledProcessError as e:
        raise RuntimeError("Could not locate SDK path: %s" % str(e))

    # OpenSSL (installed with Homebrew)
    ossl_cflags = "-I/usr/local/opt/openssl/include"
    ossl_ldflags = "-L/usr/local/opt/openssl/lib"

    # SQLite (installed with Homebrew)
    sqlite_cflags = "-I/usr/local/opt/sqlite/include"
    sqlite_ldflags = "-L/usr/local/opt/sqlite/lib"

    # Opus flags (installed with Homebrew)
    opus_cflags = "-I/usr/local/opt/opus/include"
    opus_ldflags = "-L/usr/local/opt/opus/lib"

    # VPX (installed with Homebrew)
    vpx_cflags = "-I/usr/local/opt/libvpx/include"
    vpx_ldflags = "-L/usr/local/opt/libvpx/lib"
    
    # Prepare final flags
    arch_flags =  "-arch x86_64 -mmacosx-version-min=%s" % min_osx_version
    local_cflags = " %s %s %s %s %s -mmacosx-version-min=%s -isysroot %s" % (arch_flags, ossl_cflags, sqlite_cflags, opus_cflags, vpx_cflags, min_osx_version, osx_sdk_path)
    local_ldflags = " %s %s %s %s %s -headerpad_max_install_names -isysroot %s" % (arch_flags, ossl_ldflags, sqlite_ldflags, opus_ldflags, vpx_ldflags, osx_sdk_path)
    os.environ['CFLAGS'] = os.environ.get('CFLAGS', '') + local_cflags
    os.environ['LDFLAGS'] = os.environ.get('LDFLAGS', '') + local_ldflags
    os.environ['ARCHFLAGS'] = arch_flags
    os.environ['MACOSX_DEPLOYMENT_TARGET'] = min_osx_version


from distutils import log
from distutils.dir_util import copy_tree
from distutils.errors import DistutilsError
from Cython.Distutils import build_ext


class PJSIP_build_ext(build_ext):
    config_site = ["#define PJ_SCANNER_USE_BITWISE 0",
                   "#define PJSIP_SAFE_MODULE 0",
                   "#define PJSIP_MAX_PKT_LEN 262144",
                   "#define PJSIP_UNESCAPE_IN_PLACE 1",
                   "#define PJMEDIA_AUDIO_DEV_HAS_COREAUDIO %d" % (1 if sys_platform=="darwin" else 0),
                   "#define PJMEDIA_AUDIO_DEV_HAS_ALSA %d" % (1 if sys_platform=="linux" else 0),
                   "#define PJMEDIA_AUDIO_DEV_HAS_WMME %d" % (1 if sys_platform=="win32" else 0),
                   "#define PJMEDIA_HAS_SPEEX_AEC 0",
                   "#define PJMEDIA_SRTP_HAS_AES_CM_256 1",
                   "#define PJMEDIA_HAS_SPEEX_CODEC 1",
                   "#define PJMEDIA_HAS_GSM_CODEC 1",
                   "#define PJMEDIA_HAS_ILBC_CODEC 1",
                   "#define PJMEDIA_HAS_OPENCORE_AMRNB_CODEC 0",
                   "#define PJMEDIA_HAS_OPENCORE_AMRWB_CODEC 0",
                   "#define PJMEDIA_HAS_WEBRTC_AEC %d" % (1 if re.match('i\d86|x86|x86_64', platform.machine()) else 0),
                   "#define PJMEDIA_RTP_PT_TELEPHONE_EVENTS 101",
                   "#define PJMEDIA_RTP_PT_TELEPHONE_EVENTS_STR \"101\"",
                   "#define PJMEDIA_STREAM_ENABLE_KA PJMEDIA_STREAM_KA_EMPTY_RTP",
                   "#define PJMEDIA_STREAM_VAD_SUSPEND_MSEC 0",
                   "#define PJMEDIA_CODEC_MAX_SILENCE_PERIOD -1",
                   "#define PJ_ICE_MAX_CHECKS 256",
                   "#define PJ_LOG_MAX_LEVEL 6",
                   "#define PJ_IOQUEUE_MAX_HANDLES 1024",
                   "#define PJ_DNS_RESOLVER_MAX_TTL 0",
                   "#define PJ_DNS_RESOLVER_INVALID_TTL 0",
                   "#define PJSIP_TRANSPORT_IDLE_TIME 7200",
                   "#define PJ_ENABLE_EXTRA_CHECK 1",
                   "#define PJSIP_DONT_SWITCH_TO_TCP 1",
                   "#define PJMEDIA_VIDEO_DEV_HAS_SDL 0",
                   "#define PJMEDIA_VIDEO_DEV_HAS_AVI 0",
                   "#define PJMEDIA_VIDEO_DEV_HAS_FB 1",
                   "#define PJMEDIA_VIDEO_DEV_HAS_V4L2 %d" % (1 if sys_platform=="linux" else 0),
                   "#define PJMEDIA_VIDEO_DEV_HAS_AVF %d" % (1 if sys_platform=="darwin" else 0),
                   "#define PJMEDIA_VIDEO_DEV_HAS_DSHOW %d" % (1 if sys_platform=="win32" else 0),
                   "#define PJMEDIA_VIDEO_DEV_HAS_CBAR_SRC 1",
                   "#define PJMEDIA_VIDEO_DEV_HAS_NULL 1"]

    user_options = build_ext.user_options
    user_options.extend([
        ("clean", None, "Clean PJSIP tree before compilation"),
        ("verbose", None, "Print output of PJSIP compilation process")
        ])
    boolean_options = build_ext.boolean_options
    boolean_options.extend(["clean", "verbose"])

    @staticmethod
    def distutils_exec_process(cmdline, silent=True, input=None, **kwargs):
        """Execute a subprocess and returns the returncode, stdout buffer and stderr buffer.
        Optionally prints stdout and stderr while running."""
        try:
            sub = subprocess.Popen(cmdline, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
            stdout, stderr = sub.communicate(input=input)
            returncode = sub.returncode
            if not silent:
                sys.stdout.write(stdout.decode())
                sys.stderr.write(stderr.decode())
        except OSError as e:
            if e.errno == errno.ENOENT:
                raise RuntimeError('"%s" is not present on this system' % cmdline[0])
            else:
                raise
        if returncode != 0:
            raise RuntimeError('Got return value %d while executing "%s", stderr output was:\n%s' % (returncode, " ".join(cmdline), stderr.decode()))
        return stdout.decode()

    @staticmethod
    def get_make_cmd():
        if sys_platform == "freebsd":
            return "gmake"
        else:
            return "make"

    @staticmethod
    def get_opts_from_string(line, prefix):
        """Returns all options that have a particular prefix on a commandline"""
        chunks = [chunk.strip() for chunk in line.split()]
        return [chunk[len(prefix):] for chunk in chunks if chunk.startswith(prefix)]

    @classmethod
    def get_makefile_variables(cls, makefile, silent=True):
        """Returns all variables in a makefile as a dict"""
        stdout = cls.distutils_exec_process([cls.get_make_cmd(), "-f", makefile, "-pR", makefile], silent=silent)
        return dict(tup for tup in re.findall("(^[a-zA-Z]\w+)\s*:?=\s*(.*)$", stdout, re.MULTILINE))

    @classmethod
    def makedirs(cls, path):
        try:
            os.makedirs(path)
        except OSError as e:
            if e.errno==errno.EEXIST and os.path.isdir(path) and os.access(path, os.R_OK | os.W_OK | os.X_OK):
                return
            raise

    def initialize_options(self):
        build_ext.initialize_options(self)
        self.clean = 0
        self.verbose = 0
        self.pjsip_dir = os.path.join(os.path.dirname(__file__), "deps", "pjsip")

    def configure_pjsip(self, silent=True):
        path = os.path.join(self.build_dir, "pjlib", "include", "pj", "config_site.h")
        log.info("Configuring PJSIP in %s" % path)
        with open(path, "w") as f:
            s = "\n".join(self.config_site+[""])
            f.write(s)
            
        cflags = "-DNDEBUG -g -fPIC -fno-omit-frame-pointer -fno-strict-aliasing -Wno-unused-label"
        if self.debug or hasattr(sys, 'gettotalrefcount'):
            log.info("PJSIP will be built without optimizations")
            cflags += " -O0"
        else:
            cflags += " -O2"
        env = os.environ.copy()
        env['CFLAGS'] = ' '.join(x for x in (cflags, env.get('CFLAGS', None)) if x)
        if sys_platform == "win32":
            cmd = ["bash", "configure"]
        else:
            cmd = ["./configure"]

        cmd.extend(["--disable-openh264", "--disable-l16-codec", "--disable-g7221-codec", "--disable-sdl"])
        #cmd.extend(["--disable-ilbc-codec", "--disable-speex-codec", "--disable-gsm-codec"])
        
        ffmpeg_path = env.get("SIPSIMPLE_FFMPEG_PATH", None)
        if ffmpeg_path is not None:
            cmd.append("--with-ffmpeg=%s" % os.path.abspath(os.path.expanduser(ffmpeg_path)))

        libvpx_path = env.get("SIPSIMPLE_LIBVPX_PATH", None)
        if libvpx_path is not None:
            cmd.append("--with-vpx=%s" % os.path.abspath(os.path.expanduser(libvpx_path)))

        amr_nb_path = env.get("SIPSIMPLE_AMR_NB_PATH", None)
        if amr_nb_path is not None:
            cmd.append("--with-opencore-amr=%s" % os.path.abspath(os.path.expanduser(amr_nb_path)))

        amr_wb_path = env.get("SIPSIMPLE_AMR_WB_PATH", None)
        if amr_wb_path is not None:
            cmd.append("--with-opencore-amrwbenc=%s" % os.path.abspath(os.path.expanduser(amr_wb_path)))

        if self.verbose:
            log.info(" ".join(cmd))

        self.distutils_exec_process(cmd, silent=not self.verbose, cwd=self.build_dir, env=env)
        if "#define PJ_HAS_SSL_SOCK 1\n" not in open(os.path.join(self.build_dir, "pjlib", "include", "pj", "compat", "os_auto.h")).readlines():
            os.remove(os.path.join(self.build_dir, "build.mak"))
            raise DistutilsError("PJSIP TLS support was disabled, OpenSSL development files probably not present on this system")

    def compile_pjsip(self):
        log.info("Compiling PJSIP")
        if self.verbose and sys_platform == "darwin":
            log.info(os.environ['CFLAGS'])
            log.info(os.environ['LDFLAGS'])
        self.distutils_exec_process([self.get_make_cmd()], silent=not self.verbose, cwd=self.build_dir)

    def clean_pjsip(self):
        log.info("Cleaning PJSIP")
        try:
            shutil.rmtree(self.build_dir)
        except OSError as e:
            if e.errno == errno.ENOENT:
                return
            raise

    def update_extension(self, extension, silent=True):
        build_mak_vars = self.get_makefile_variables(os.path.join(self.build_dir, "build.mak"))
        extension.include_dirs = self.get_opts_from_string(build_mak_vars["PJ_CFLAGS"], "-I")
        extension.library_dirs = self.get_opts_from_string(build_mak_vars["PJ_LDFLAGS"], "-L")
        extension.libraries = self.get_opts_from_string(build_mak_vars["PJ_LDLIBS"], "-l")
        extension.define_macros = [tuple(define.split("=", 1)) for define in self.get_opts_from_string(build_mak_vars["PJ_CFLAGS"], "-D")]
        extension.define_macros.append(("PJ_SVN_REVISION", open(os.path.join(self.build_dir, "base_rev"), "r").read().strip()))
        #extension.define_macros.append(("__PYX_FORCE_INIT_THREADS", 1))
        extension.extra_compile_args.append("-Wno-unused-function")    # silence warning

        if sys_platform == "darwin":
            extension.define_macros.append(("MACOSX_DEPLOYMENT_TARGET", min_osx_version))
            frameworks = re.findall("-framework (\S+)(?:\s|$)", build_mak_vars["PJ_LDLIBS"])
            extension.extra_link_args = list(itertools.chain(*(("-framework", val) for val in frameworks)))
            extension.extra_link_args.append("-mmacosx-version-min=%s" % min_osx_version)
            extension.extra_compile_args.append("-mmacosx-version-min=%s" % min_osx_version)
            extension.library_dirs.append("%s/usr/lib" % osx_sdk_path)
            extension.include_dirs.append("%s/usr/include" % osx_sdk_path)

        extension.depends = build_mak_vars["PJ_LIB_FILES"].split()
        self.libraries = extension.depends[:]

    def cython_sources(self, sources, extension, silent=True):
        log.info("Compiling Cython extension %s" % extension.name)
        if extension.name == "sipsimple.core._core":
            self.build_dir = os.path.join(self.build_temp, "pjsip")
            if self.clean:
                self.clean_pjsip()
            copy_tree(self.pjsip_dir, self.build_dir, verbose=0)
            try:
                if not os.path.exists(os.path.join(self.build_dir, "build.mak")):
                    self.configure_pjsip(silent=silent)
                self.update_extension(extension, silent=silent)
                self.compile_pjsip()
            except RuntimeError as e:
                log.info("Error building %s: %s" % (extension.name, str(e)))
                return None
        return build_ext.cython_sources(self, sources, extension)
