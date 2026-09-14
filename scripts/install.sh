#!/bin/sh
# install.sh: build arc and install it as a display-manager session.
#
# Installs the nile compositor + nshell binaries, the launch-arc session
# launcher, and an "Arc Desktop" entry for display managers (GDM, SDDM,
# LightDM read $datadir/wayland-sessions/*.desktop).
#
# Usage: ./scripts/install.sh [options] [-Dzig-build-flags...]
#   --prefix <dir>   install prefix (default: /usr/local)
#   --user           user install: prefix $HOME/.local, no root needed
#   --xwayland       build nile with Xwayland support (-Dxwayland=true)
#   --debug          debug build instead of ReleaseSafe
#   --uninstall      remove installed files instead of installing
#   -h, --help       print this message and exit
#   -D* flags are passed straight to `zig build`.
#
# Examples:
#   sudo ./scripts/install.sh                  # system install
#   ./scripts/install.sh --user                # ~/.local install
#   sudo ./scripts/install.sh --uninstall      # remove system install
#   ./scripts/install.sh --user --xwayland     # user install + Xwayland
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

prefix="/usr/local"
user_install=0
uninstall=0
xwayland=0
optimize="ReleaseSafe"

usage() {
    sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --prefix)
            prefix="${2:?--prefix needs a directory}"
            shift 2
            ;;
        --prefix=*)
            prefix="${1#--prefix=}"
            shift
            ;;
        --user)
            user_install=1
            shift
            ;;
        --uninstall)
            uninstall=1
            shift
            ;;
        --xwayland)
            xwayland=1
            shift
            ;;
        --debug)
            optimize="Debug"
            shift
            ;;
        --)
            shift
            break
            ;;
        -D*)
            break
            ;;
        *)
            echo "install.sh: unknown option '$1' (see --help)" >&2
            exit 1
            ;;
    esac
done

if [ "$user_install" -eq 1 ]; then
    prefix="$HOME/.local"
fi

bindir="$prefix/bin"
sessiondir="$prefix/share/wayland-sessions"

# Files this script manages (binaries come from `zig build install`;
# the launcher and session entry are copied below).
bin_files="nile nshell bank-server bank-client launch-arc"

# True when the install locations are not writable (checks the nearest
# existing parent for paths that do not exist yet).
needs_root() {
    for d in "$bindir" "$sessiondir"; do
        p="$d"
        while [ ! -e "$p" ]; do
            p="$(dirname "$p")"
        done
        if [ ! -w "$p" ]; then
            return 0
        fi
    done
    return 1
}

if [ "$(id -u)" -ne 0 ] && needs_root; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "install.sh: $prefix is not writable (run as root or use --user)" >&2
        exit 1
    fi
    echo "install.sh: re-execing with sudo for $prefix" >&2
    # Rebuild our own flags; remaining "$@" is zig-build passthrough
    # (-D*), which re-parses to the same break point.
    elevate="--prefix=$prefix"
    [ "$uninstall" -eq 1 ] && elevate="$elevate --uninstall"
    [ "$xwayland" -eq 1 ] && elevate="$elevate --xwayland"
    [ "$optimize" != "ReleaseSafe" ] && elevate="$elevate --debug"
    # shellcheck disable=SC2086
    exec sudo -- "$0" $elevate "$@"
fi

if [ "$uninstall" -eq 1 ]; then
    for f in $bin_files; do
        rm -f "$bindir/$f"
    done
    rm -f "$prefix/lib/libbank.a" "$sessiondir/arc.desktop"
    rmdir -p "$sessiondir" 2>/dev/null || true
    echo "install.sh: uninstalled Arc Desktop from $prefix"
    exit 0
fi

if ! command -v zig >/dev/null 2>&1; then
    echo "install.sh: zig not found in PATH" >&2
    exit 1
fi

# The shell links the ui/ DVUI fork: refuse with a hint instead of a
# wall of missing-file errors when the submodule was never fetched.
if [ ! -f "$root/ui/src/dvui.zig" ]; then
    if [ -d "$root/.git" ] && command -v git >/dev/null 2>&1; then
        echo "install.sh: fetching ui/ submodule..." >&2
        git -C "$root" submodule update --init -- ui
    else
        echo "install.sh: ui/ submodule is missing (git submodule update --init)" >&2
        exit 1
    fi
fi

zig_build_args="-Dllvm=true -Doptimize=$optimize"
if [ "$xwayland" -eq 1 ]; then
    zig_build_args="$zig_build_args -Dxwayland=true"
fi

# shellcheck disable=SC2086
zig build $zig_build_args --prefix "$prefix" "$@"

mkdir -p "$bindir" "$sessiondir"
install -m 0755 "$root/scripts/launch-arc" "$bindir/launch-arc"
install -m 0644 "$root/scripts/arc.desktop" "$sessiondir/arc.desktop"

echo "install.sh: installed Arc Desktop to $prefix"
echo "  binaries:  $bindir/nile $bindir/nshell"
echo "  launcher:  $bindir/launch-arc"
echo "  session:   $sessiondir/arc.desktop"
echo "Pick \"Arc Desktop\" in your display manager to start the session."
