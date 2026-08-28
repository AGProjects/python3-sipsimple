#!/bin/bash
#
# SYNC NOTE — this script exists in two repositories and they are kept
# independent on purpose:
#
#     blink/build_scripts/02-install-c-deps.sh
#     python3-sipsimple/mac/02-install-c-deps.sh
#
# They are NOT identical — the wording differs and the Blink copy also installs
# create-dmg — but the LOGIC is shared. When you change how ports are inspected,
# fixed or verified in one, port the change to the other. To see what diverged:
#
#     diff ~/work/blink/build_scripts/02-install-c-deps.sh \
#          ~/work/python3-sipsimple/mac/02-install-c-deps.sh
#
#
# 02-install-c-deps.sh — install the MacPorts C libraries python3-sipsimple
# needs, and keep them universal (arm64 + x86_64), from any starting state.
#
# WHY UNIVERSAL HERE, WHEN THIS REPO BUILDS NATIVE
#
# /opt/local is shared with the Blink build, which ships a universal app. If
# this script installed plain (native-only) ports it would deactivate Blink's
# universal builds underneath it — MacPorts activates one version at a time —
# and the next Blink release would silently lose its Intel slice. Universal
# ports serve a native build perfectly well (the native slice is what gets
# linked), so keeping the prefix universal costs build time and nothing else.
#
# WHY ffmpeg IS PINNED
#
# pjmedia's ffmpeg glue (pjmedia/src/pjmedia-codec/ffmpeg_vid_codecs.c) guards
# its API use with LIBAVCODEC_VER_AT_LEAST(...) checks that top out at 58,137
# — libavcodec 58 is the ffmpeg 4.x series. ffmpeg 5 removed the encode/decode
# entry points that code calls. `sudo port install ffmpeg` installs whatever
# MacPorts ships today (9.x), so this script builds ffmpeg 4.4.5 from
# mac/ffmpeg/Portfile through a local ports repository instead, and refuses to
# proceed if MacPorts would resolve the upstream port.
#
# Idempotent and convergent: run it on a fresh MacPorts install, on a
# half-universal tree, or after MacPorts upgraded something behind your back,
# and it arrives at the same place. Run it twice and the second run does
# nothing.
#
# HOW IT DECIDES WHAT TO FIX
#
# Not from a hardcoded list of dylib paths — that guesses wrong (MacPorts 3.x
# moved libssl to /opt/local/libexec/openssl3/lib) and it misses dependencies
# of dependencies. Instead:
#
#   1. REQUIRED_PORTS below are installed if absent. These are the ports
#      pjsip/sipsimple and Blink link directly.
#   2. `port contents` gives the dylibs each of those ports actually
#      installed — no globbing, no assumptions about layout.
#   3. otool walks the dependency graph from those dylibs, following anything
#      under /opt/local, to build the full closure. This is the same set
#      11-check-macports-deps.sh audits after _core is built, computed here
#      before it exists.
#   4. Every library in the closure must be universal. Any that is not is
#      mapped back to its port with `port provides`, and that port is fixed.
#   5. Repeat until the closure is clean or nothing improves. Fixing one port
#      can pull in a new single-arch dependency, so one pass is not enough.
#
# HOW IT FIXES A PORT, SAFELY
#
#   `port upgrade --enforce-variants <p> +universal` first — the documented
#   way to add a variant to an installed port, with nothing uninstalled, so
#   ports that depend on it are never at risk. Only if that fails, and only
#   when `port dependents` is empty, does it purge every registered version
#   (addressing each by full version, since a bare uninstall fails when two
#   are registered) and reinstall. A port with dependents is reported, never
#   force-removed.
#
#   Each fix is verified with lipo afterwards. `port` reporting success is not
#   evidence: an upgrade can deactivate a working universal build in favour of
#   a newer single-arch one and still exit 0.
#
#   A +universal build failure is retried once with
#   -Wno-error=implicit-function-declaration via a local Portfile override —
#   clang 16+ turned implicit declarations into hard errors, which older
#   autotools and meson sources trip over.
#
# Usage:
#   ./02-install-c-deps.sh              show the plan, ask, then converge
#   ./02-install-c-deps.sh --dry-run    report only, change nothing
#   ./02-install-c-deps.sh --yes        no prompt (unattended)
#   ./02-install-c-deps.sh --only x264  act on one port
#
# Exit: 0 = every library in the closure is universal.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCALPORTS="/opt/local/ports"
SOURCES_CONF="/opt/local/etc/macports/sources.conf"
CLANG_WORKAROUND="-Wno-error=implicit-function-declaration"
SNAPSHOT="$SCRIPT_DIR/ports-installed.txt"
MAX_PASSES=4

# Ports python3-sipsimple / pjsip link directly. ffmpeg LAST — it links x264,
# opus and vpx, which must be universal before it is built.
REQUIRED_PORTS="pkgconfig yasm gmp mpfr libmpc libuuid openssl sqlite3 gnutls libopus libvpx x264 bzip2 libiconv lzo2 ffmpeg"

DRY=0; ASSUME_YES=0; ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --yes|-y)  ASSUME_YES=1 ;;
        --only)    shift; ONLY="${1:-}" ;;
        -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

command -v port  >/dev/null 2>&1 || { echo "error: MacPorts not found (https://www.macports.org)" >&2; exit 1; }
command -v otool >/dev/null 2>&1 || { echo "error: otool not found (xcode-select --install)" >&2; exit 1; }
command -v lipo  >/dev/null 2>&1 || { echo "error: lipo not found (xcode-select --install)" >&2; exit 1; }

# Detect the HARDWARE: `uname -m` reports x86_64 when this shell itself runs
# under Rosetta, which would silently disable the universal build.
UNIVERSAL=0; VARIANT=""
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
    UNIVERSAL=1; VARIANT="+universal"
fi

[ -n "$ONLY" ] && REQUIRED_PORTS="$ONLY"

TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

# ------------------------------------------------------------- primitives --

run() { echo "    \$ $*"; "$@"; }

port_is_installed() { port -q installed "$1" 2>/dev/null | grep -q '@'; }

port_versions() {
    port -q installed "$1" 2>/dev/null | sed 's/^[[:space:]]*//' | awk '$2 ~ /^@/ {print $2}'
}

port_active_version() {
    port -q installed "$1" 2>/dev/null | sed 's/^[[:space:]]*//' \
        | awk '/\(active\)/ && $2 ~ /^@/ {print $2}'
}

# Ports that would break if this one were removed. `port -f uninstall` walks
# straight past these ("Warning: Uninstall forced"), which is how you end up
# with a half-removed openssl underneath curl, git and python.
port_dependents() {
    port -q dependents "$1" 2>/dev/null | sed 's/^[[:space:]]*//' \
        | grep -v '^$' | grep -v 'has no dependents'
}

# The dylibs this port actually installed — authoritative, no globbing.
port_dylibs() {
    port contents "$1" 2>/dev/null | awk '/^[[:space:]]*\// {print $1}' | grep '\.dylib$'
}

port_providing() {
    port provides "$1" 2>/dev/null | awk '/is provided by/ {print $NF}'
}

lib_is_universal() {
    local a
    a="$(lipo -archs "$1" 2>/dev/null)" || return 1
    [ -z "$a" ] && return 1
    [ "$UNIVERSAL" -eq 0 ] && return 0
    case " $a " in *" x86_64 "*) ;; *) return 1 ;; esac
    case " $a " in *" arm64 "*) ;; *) return 1 ;; esac
    return 0
}

# Every /opt/local Mach-O reachable from the required ports' dylibs.
compute_closure() {
    local seed lib dep
    : > "$TMPD/seen"; : > "$TMPD/work"
    for seed in $REQUIRED_PORTS; do
        port_is_installed "$seed" || continue
        port_dylibs "$seed" >> "$TMPD/work"
    done
    sort -u "$TMPD/work" > "$TMPD/work.u"; mv "$TMPD/work.u" "$TMPD/work"

    while [ -s "$TMPD/work" ]; do
        lib="$(head -1 "$TMPD/work")"
        sed -i '' '1d' "$TMPD/work" 2>/dev/null || sed -i '1d' "$TMPD/work"
        [ -f "$lib" ] || continue
        grep -qxF "$lib" "$TMPD/seen" && continue
        echo "$lib" >> "$TMPD/seen"
        for dep in $(otool -L "$lib" 2>/dev/null | tail -n +2 | awk '{print $1}'); do
            case "$dep" in
                /opt/local/*)
                    grep -qxF "$dep" "$TMPD/seen" || echo "$dep" >> "$TMPD/work" ;;
            esac
        done
    done
    sort -u "$TMPD/seen"
}

# Non-universal members of the closure -> "library<TAB>port"
scan_offenders() {
    local lib p
    : > "$TMPD/offenders"
    compute_closure > "$TMPD/closure"
    while IFS= read -r lib; do
        [ -f "$lib" ] || continue
        if ! lib_is_universal "$lib"; then
            p="$(port_providing "$lib")"
            printf '%s\t%s\n' "$lib" "${p:-<unknown>}" >> "$TMPD/offenders"
        fi
    done < "$TMPD/closure"
    cat "$TMPD/offenders" 2>/dev/null
}

# ------------------------------------------------------------------ fixes --

install_port() {
    if [ -n "$VARIANT" ]; then run sudo port -N install "$1" "$VARIANT"
    else                        run sudo port -N install "$1"; fi
}

#   --enforce-variants: "Upgrade all given ports and their dependencies where
#   the installed variants do not match those requested on the command line,
#   even if those ports aren't outdated."
upgrade_enforce_variants() {
    if [ -n "$VARIANT" ]; then run sudo port -N upgrade --enforce-variants "$1" "$VARIANT"
    else                        run sudo port -N upgrade "$1"; fi
}

purge_all_versions() {
    local p="$1" v
    for v in $(port_versions "$p"); do
        run sudo port -N -f uninstall "$p" "$v" || true
    done
    sudo port clean --all "$p" >/dev/null 2>&1 || true
}

purge_inactive_versions() {
    local p="$1" v active
    active="$(port_active_version "$p")"
    for v in $(port_versions "$p"); do
        [ "$v" = "$active" ] && continue
        run sudo port -N -f uninstall "$p" "$v" || true
    done
}

add_clang_workaround() {
    local p="$1" pf cat dest
    [ "$p" = "ffmpeg" ] && return 1          # ffmpeg already has our Portfile
    pf="$(port file "$p" 2>/dev/null)"; [ -f "$pf" ] || return 1
    cat="$(port info --category --line "$p" 2>/dev/null | awk '{print $1}')"; [ -n "$cat" ] || return 1
    dest="$LOCALPORTS/$cat/$p"
    echo "    applying clang workaround: $dest/Portfile"
    sudo mkdir -p "$dest" && sudo cp "$pf" "$dest/Portfile" || return 1
    printf '\n# Added by 02-install-c-deps.sh: clang 16+ makes implicit function\n# declarations a hard error, which these sources predate.\nconfigure.cflags-append  %s\n' \
        "$CLANG_WORKAROUND" | sudo tee -a "$dest/Portfile" >/dev/null || return 1
    sudo portindex "$LOCALPORTS" >/dev/null 2>&1 || return 1
    return 0
}

# Returns 0 if $1 ends up universal.
fix_port() {
    local p="$1" deps
    echo "==> fixing $p"

    if ! port_is_installed "$p"; then
        install_port "$p" || {
            echo "    build failed — retrying once with $CLANG_WORKAROUND"
            add_clang_workaround "$p" && install_port "$p" || return 1
        }
        return 0
    fi

    # 1. In-place variant upgrade: nothing is uninstalled, dependents safe.
    upgrade_enforce_variants "$p"
    if port_all_dylibs_universal "$p"; then
        purge_inactive_versions "$p"
        return 0
    fi

    # 2. Still wrong. Purging is destructive — refuse when others depend on it.
    deps="$(port_dependents "$p")"
    if [ -n "$deps" ]; then
        echo "    NOT purging $p — these ports depend on it:" >&2
        printf '%s\n' "$deps" | sed 's/^/        /' >&2
        echo "    Fix by hand, or uninstall the dependents first." >&2
        return 1
    fi

    purge_all_versions "$p"
    install_port "$p" || {
        echo "    build failed — retrying once with $CLANG_WORKAROUND"
        add_clang_workaround "$p" && install_port "$p" || return 1
    }
    return 0
}

port_all_dylibs_universal() {
    local lib found=0
    for lib in $(port_dylibs "$1"); do
        [ -f "$lib" ] || continue
        found=1
        lib_is_universal "$lib" || return 1
    done
    [ "$found" -eq 1 ] || return 0     # tool-only port: nothing to check
    return 0
}

# ------------------------------------------------- local ports repository --

ensure_local_ports_repo() {
    local tmp tcl res resolved
    echo "==> Local ports repository (pinned ffmpeg Portfile)"

    [ -f "$SCRIPT_DIR/ffmpeg/Portfile" ] || {
        echo "    error: $SCRIPT_DIR/ffmpeg/Portfile is missing." >&2; return 1; }

    run sudo mkdir -p "$LOCALPORTS/multimedia/ffmpeg" || return 1
    run sudo cp "$SCRIPT_DIR/ffmpeg/Portfile" "$LOCALPORTS/multimedia/ffmpeg/Portfile" || return 1

    if ! grep -qE '^[[:space:]]*file://'"$LOCALPORTS" "$SOURCES_CONF" 2>/dev/null; then
        echo "    prepending file://$LOCALPORTS to $SOURCES_CONF"
        tmp="$(mktemp)" || return 1
        { echo "file://$LOCALPORTS"; cat "$SOURCES_CONF"; } > "$tmp"
        run sudo cp "$tmp" "$SOURCES_CONF" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
    fi

    # A dangling _resources link from an earlier attempt actively breaks
    # PortGroup lookup for this repository. Clear it before indexing.
    if [ -L "$LOCALPORTS/_resources" ] && [ ! -d "$LOCALPORTS/_resources" ]; then
        echo "    removing dangling $LOCALPORTS/_resources"
        run sudo rm -f "$LOCALPORTS/_resources"
    fi

    run sudo portindex "$LOCALPORTS" >/dev/null || return 1
    resolved="$(port file ffmpeg 2>/dev/null)"

    # PortGroups normally resolve from the prefix without help. Only if the
    # index did not take do we go looking for them and link them in.
    case "$resolved" in
        "$LOCALPORTS"/*) ;;
        *)
            if [ ! -e "$LOCALPORTS/_resources" ]; then
                tcl="$(find /opt/local/share/macports/resources /opt/local/var/macports/sources \
                            -type f -name 'muniversal-1.0.tcl' 2>/dev/null | head -1)"
                if [ -n "$tcl" ]; then
                    res="$(dirname "$(dirname "$(dirname "$tcl")")")"
                    echo "    index did not take; linking PortGroups"
                    run sudo ln -s "$res" "$LOCALPORTS/_resources" || return 1
                    run sudo portindex "$LOCALPORTS" >/dev/null || return 1
                    resolved="$(port file ffmpeg 2>/dev/null)"
                fi
            fi
            ;;
    esac

    case "$resolved" in
        "$LOCALPORTS"/*) echo "    ffmpeg resolves to $resolved"; echo; return 0 ;;
    esac

    cat >&2 <<EOF
    error: MacPorts resolves ffmpeg to
             ${resolved:-<nothing>}
           expected a Portfile under $LOCALPORTS.

    The local repository is NOT in use. Installing ffmpeg now would build the
    upstream port (9.x), pulling in ~80 unrelated dependencies and an API
    pjmedia cannot compile against. Refusing to continue.

    Check what portindex says:
        sudo portindex $LOCALPORTS
    "PortGroup ... could not be located" names a PortGroup this MacPorts no
    longer ships; comment it out of mac/ffmpeg/Portfile along with
    whatever used it. (Building the Portfile in place from the repo directory
    does not work: MacPorts builds as the `macports` user and cannot write its
    statefile into your checkout.)
EOF
    return 1
}

# ------------------------------------------------------------------ report --

echo "==> Inspecting /opt/local"
[ "$UNIVERSAL" -eq 1 ] \
    && echo "    Apple Silicon: every library Blink links must be universal (arm64 + x86_64)" \
    || echo "    Intel host: single-arch is expected, no +universal"
echo

missing=""
for p in $REQUIRED_PORTS; do
    port_is_installed "$p" || missing="$missing $p"
done

offenders="$(scan_offenders)"
closure_n="$(wc -l < "$TMPD/closure" | tr -d ' ')"

echo "    libraries in the /opt/local closure : $closure_n"
echo "    not universal                       : $(printf '%s' "$offenders" | grep -c . )"
[ -n "$missing" ] && echo "    ports not installed                 :$missing"
echo

if [ -n "$offenders" ]; then
    echo "    LIBRARY                                             PORT"
    printf '%s\n' "$offenders" | while IFS="$(printf '\t')" read -r lib p; do
        printf "    %-51s %s\n" "$lib" "$p"
    done
    echo
fi

# Ports to act on: everything not installed, plus every port providing a
# non-universal library in the closure.
todo="$missing"
if [ -n "$offenders" ]; then
    for p in $(printf '%s\n' "$offenders" | awk -F"$(printf '\t')" '{print $2}' | sort -u); do
        [ "$p" = "<unknown>" ] && continue
        case " $todo " in *" $p "*) ;; *) todo="$todo $p" ;; esac
    done
fi
todo="$(echo $todo)"

if [ -z "$todo" ]; then
    echo "==> Nothing to do — every library the SDK links is universal."
    exit 0
fi

echo "==> Ports to fix: $todo"
echo
[ "$DRY" -eq 1 ] && { echo "==> --dry-run: stopping before any change."; exit 0; }

if [ "$ASSUME_YES" -ne 1 ]; then
    if [ -t 0 ]; then
        printf "Proceed? [y/N] "; read -r answer
        case "$answer" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1 ;; esac
        echo
    else
        echo "error: not a tty and --yes not given; refusing to modify ports." >&2
        exit 1
    fi
fi

# ----------------------------------------------------------------- execute --

case " $todo " in *" ffmpeg "*) ensure_local_ports_repo || exit 1 ;; esac

pass=1
failed=""
while [ "$pass" -le "$MAX_PASSES" ]; do
    echo "==> pass $pass: $todo"
    echo
    for p in $todo; do
        case " $failed " in *" $p "*) continue ;; esac
        fix_port "$p" || failed="$failed $p"
        echo
    done

    offenders="$(scan_offenders)"
    [ -z "$offenders" ] && break

    next=""
    for p in $(printf '%s\n' "$offenders" | awk -F"$(printf '\t')" '{print $2}' | sort -u); do
        [ "$p" = "<unknown>" ] && continue
        case " $failed " in *" $p "*) continue ;; esac
        next="$next $p"
    done
    next="$(echo $next)"

    # No new ports to try, or the same set again with no progress: stop.
    if [ -z "$next" ] || [ "$next" = "$todo" ]; then
        todo="$next"
        break
    fi
    todo="$next"
    pass=$((pass + 1))
done

# MacPorts' libuuid ships a uuid.h that shadows the system header and breaks
# the sipsimple build. Last, because any libuuid (re)install restores it.
if [ -f /opt/local/include/uuid/uuid.h ]; then
    echo "==> Moving MacPorts uuid.h aside (conflicts with the system header)"
    run sudo mv -f /opt/local/include/uuid/uuid.h /opt/local/include/uuid/uuid.h.old
    echo
fi

# ------------------------------------------------------------ final audit --

echo "==> Final audit"
offenders="$(scan_offenders)"
closure_n="$(wc -l < "$TMPD/closure" | tr -d ' ')"
echo "    libraries in the /opt/local closure : $closure_n"

if [ -z "$offenders" ] && [ -z "$failed" ]; then
    echo "    all universal"
    echo
    port -q installed > "$SNAPSHOT" 2>/dev/null \
        && echo "    environment snapshot written to ${SNAPSHOT#$SCRIPT_DIR/}"
    echo
    echo "==> OK — C dependencies are installed and universal."
    echo "    Next: ./02b-install-bcg729.sh, then ./03-install-python-deps.sh"
    exit 0
fi

echo
[ -n "$offenders" ] && { echo "    still not universal:" >&2
    printf '%s\n' "$offenders" | sed 's/^/      /' >&2; }
[ -n "$failed" ] && echo "    ports that could not be fixed:$failed" >&2
cat >&2 <<'EOF'

==> FAILED — some libraries the SDK links are still single-arch.

Read the MacPorts log named in the error above. On current toolchains the
usual cause is clang 16+ rejecting implicit function declarations; this script
already retries once with -Wno-error=implicit-function-declaration via a local
Portfile in /opt/local/ports. If that was not enough the port needs a real fix:
check whether an older version builds, or build each arch separately and lipo
the results.

Do NOT run 04-install_sipsimple.sh while anything is single-arch. For a native
build you would lose nothing today, but Blink cross-builds x86_64 against this
same prefix with -undefined dynamic_lookup: a single-arch dependency is
silently dropped there and the Intel app crashes at startup.
EOF
exit 1
