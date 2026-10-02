#!/usr/bin/env bash
# verify-share.sh: prove the screen-share pipeline works, on a private bus.
#
# Why a private bus: xdg-desktop-portal is a per-user service that picks its
# backends once, at startup, from XDG_CURRENT_DESKTOP. Inside another desktop
# session (Plasma being the common case) that desktop's portal already owns
# ScreenCast and will answer with its own picker, capturing from its own
# compositor. Exporting XDG_CURRENT_DESKTOP does not help, because the
# frontend is already running.
#
# So we do not use the session bus at all. We start our own dbus-daemon, point
# nshell at it, and talk to org.freedesktop.impl.portal.desktop.arc directly.
# Nothing another desktop is doing can interfere.
#
# The image check itself does not even need D-Bus: nile-share-verify speaks the
# bank protocol and asks the compositor to render one share frame.
#
# Usage:
#   scripts/verify-share.sh              # compositor + image checks
#   scripts/verify-share.sh --with-bus   # also check the D-Bus portal on a private bus
#
# Env:
#   WLR_BACKENDS   passed through (try `headless` if there is no seat/GPU)
#   WLR_HEADLESS_OUTPUTS  count for the headless backend (default 1)
#   KEEP_TMP=1     do not delete the scratch runtime dir

set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

with_bus=0
for arg in "$@"; do
    case "$arg" in
        --with-bus) with_bus=1 ;;
        *) echo "verify-share.sh: unknown argument '$arg'" >&2; exit 64 ;;
    esac
done

nile="$root/zig-out/bin/nile"
nshell="$root/zig-out/bin/nshell"
verify="$root/zig-out/bin/nile-share-verify"

for b in "$nile" "$verify"; do
    if [ ! -x "$b" ]; then
        echo "verify-share.sh: $b missing. Run: zig build -Dllvm" >&2
        exit 66
    fi
done

tmp="$(mktemp -d /tmp/arc-verify.XXXXXX)"
runtime="$tmp/runtime"
mkdir -p "$runtime"
chmod 700 "$runtime"

bus_pid=""
nile_pid=""
nshell_pid=""

cleanup() {
    [ -n "$client_pid" ] && kill "$client_pid" 2>/dev/null || true
    [ -n "$nshell_pid" ] && kill "$nshell_pid" 2>/dev/null || true
    [ -n "$nile_pid" ] && kill "$nile_pid" 2>/dev/null || true
    [ -n "$bus_pid" ] && kill "$bus_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    if [ "${KEEP_TMP:-0}" = "1" ]; then
        echo "verify-share.sh: scratch kept at $tmp"
    else
        rm -rf "$tmp"
    fi
}
trap cleanup EXIT

echo "==> scratch: $tmp"

# --- private session bus ---------------------------------------------------
# Started unconditionally (cheap) so the compositor inherits a bus address
# that is definitely not the desktop's.
echo "==> starting a private session bus"
dbus_addr="$(dbus-daemon --session --nofork --print-address=1 \
    --address="unix:path=$tmp/bus" >"$tmp/bus.addr" 2>"$tmp/bus.err" & echo $!)" || {
    echo "verify-share.sh: dbus-daemon failed to start:" >&2
    cat "$tmp/bus.err" >&2 || true
    exit 69
}
bus_pid="$dbus_addr"

for _ in $(seq 1 50); do
    [ -S "$tmp/bus" ] && break
    sleep 0.1
done
if [ ! -S "$tmp/bus" ]; then
    echo "verify-share.sh: private bus socket never appeared" >&2
    cat "$tmp/bus.err" >&2 || true
    exit 69
fi
export DBUS_SESSION_BUS_ADDRESS="unix:path=$tmp/bus"
export XDG_RUNTIME_DIR="$runtime"
# Make sure nothing inherited from the outer session leaks in -- notably a
# WAYLAND_DISPLAY, which would make wlroots autocreate a *nested* wayland
# backend that then has nothing to connect to.
unset WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP || true
# Headless by default: there is usually no spare seat or GPU for a nested
# session. Override with WLR_BACKENDS if you want to drive real hardware.
export WLR_BACKENDS="${WLR_BACKENDS:-headless}"
export WLR_RENDERER="${WLR_RENDERER:-pixman}"
export WLR_HEADLESS_OUTPUTS="${WLR_HEADLESS_OUTPUTS:-1}"
export XDG_CONFIG_HOME="$tmp/config"
mkdir -p "$XDG_CONFIG_HOME"

# --- compositor ------------------------------------------------------------
# /tmp/arcos is where nilebank hardcodes its socket, so a stale one from a
# previous run would be mistaken for ours.
rm -f /tmp/arcos/compositor.sock 2>/dev/null || true

echo "==> starting nile"
"$nile" -c "$nshell" >"$tmp/nile.log" 2>&1 &
nile_pid=$!

for _ in $(seq 1 100); do
    [ -S /tmp/arcos/compositor.sock ] && break
    if ! kill -0 "$nile_pid" 2>/dev/null; then
        echo "verify-share.sh: nile exited during startup:" >&2
        cat "$tmp/nile.log" >&2 || true
        exit 70
    fi
    sleep 0.1
done
if [ ! -S /tmp/arcos/compositor.sock ]; then
    echo "verify-share.sh: compositor socket never appeared" >&2
    cat "$tmp/nile.log" >&2 || true
    exit 70
fi
echo "    compositor up (pid $nile_pid)"

# Point clients at nile's socket. With the headless backend it lands in our
# own XDG_RUNTIME_DIR as wayland-N, and N is not guaranteed to be 1.
wayland_sock=""
for _ in $(seq 1 60); do
    wayland_sock="$(ls "$runtime"/wayland-* 2>/dev/null | head -1 || true)"
    [ -n "$wayland_sock" ] && break
    sleep 0.1
done
if [ -n "$wayland_sock" ]; then
    export WAYLAND_DISPLAY="$(basename "$wayland_sock")"
    echo "==> clients will connect to $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
else
    echo "==> warning: no wayland socket found; the test client may not start" >&2
fi

# --- a window to hide ------------------------------------------------------
# The redaction check needs something on screen to black out. Prefer a native
# Wayland terminal; fall back to whatever can put a window up.
client=""
for cand in alacritty kitty glxgears; do
    if command -v "$cand" >/dev/null 2>&1; then client="$cand"; break; fi
done

client_pid=""
if [ -n "$client" ]; then
    echo "==> opening a test window with $client"
    case "$client" in
        alacritty) "$client" -o 'window.dimensions.columns=80' -o 'window.dimensions.lines=24' \
                       -o 'window.dimensions.pixels.width=640' -o 'window.dimensions.pixels.height=480' \
                       -o 'app_id="ArcShareVerify"' >"$tmp/client.log" 2>&1 & ;;
        kitty)     "$client" --class ArcShareVerify >"$tmp/client.log" 2>&1 & ;;
        glxgears)  "$client" >"$tmp/client.log" 2>&1 & ;;
    esac
    client_pid=$!
    # Wait for it to map, otherwise the window list is still empty.
    for _ in $(seq 1 60); do
        sleep 0.25
        if "$verify" --count-windows >/dev/null 2>&1; then break; fi
        kill -0 "$client_pid" 2>/dev/null || break
    done
    sleep 1
else
    echo "==> no test client found (alacritty/kitty/glxgears); the redaction check will be skipped"
fi

# --- D-Bus portal, on our private bus --------------------------------------
if [ "$with_bus" = "1" ]; then
    if [ -x "$nshell" ]; then
        # nshell runs as the compositor's startup command, so it is already
        # coming up; give the portal a moment to claim its name.
        echo "==> waiting for the portal to claim org.freedesktop.impl.portal.desktop.arc"
        claimed=0
        for _ in $(seq 1 100); do
            if gdbus introspect --session \
                --dest org.freedesktop.impl.portal.desktop.arc \
                --object-path /org/freedesktop/impl/portal/ScreenCast \
                >"$tmp/introspect.txt" 2>"$tmp/introspect.err"; then
                claimed=1
                break
            fi
            sleep 0.1
        done

        if [ "$claimed" = "1" ]; then
            echo "    PASS  portal answers on the private bus"
            # Proper handshake: the impl interface needs a session before it
            # will accept a source selection. Start is deliberately not called
            # -- it blocks on the share picker, which needs a human.
            if gdbus call --session \
                --dest org.freedesktop.impl.portal.desktop.arc \
                --object-path /org/freedesktop/impl/portal/ScreenCast \
                --method org.freedesktop.impl.portal.ScreenCast.CreateSession \
                "/verify/h" "/verify/sh" "verify-share" "{}" \
                >"$tmp/create.txt" 2>&1; then
                echo "    PASS  CreateSession answered"
                # Reply is "('session_id',)" -- the object path to use below.
                sess="$(sed -n "s/.*('\([^']*\)'.*/\1/p" "$tmp/create.txt")"
                echo "    session: $sess"
                if gdbus call --session \
                    --dest org.freedesktop.impl.portal.desktop.arc \
                    --object-path "$sess" \
                    --method org.freedesktop.impl.portal.ScreenCast.SelectSources \
                    "{}" "{}" "verify-share" \
                    "{'types': <uint32 1>, 'multiple': <false>, 'cursor_mode': <uint32 2>}" \
                    >"$tmp/selectsources.txt" 2>&1; then
                    echo "    PASS  SelectSources answered ($(cat "$tmp/selectsources.txt"))"
                else
                    echo "    FAIL  SelectSources:"
                    cat "$tmp/selectsources.txt" >&2 || true
                fi
            else
                echo "    FAIL  CreateSession:"
                cat "$tmp/create.txt" >&2 || true
            fi
            grep -E 'AvailableSourceTypes|AvailableCursorModes|version' "$tmp/introspect.txt" || true
        else
            echo "    FAIL  portal never claimed its bus name" >&2
            tail -n 30 "$tmp/nile.log" >&2 || true
        fi
    fi
fi

# --- the actual image check ------------------------------------------------
echo
echo "==> verifying the share image (writes share-visible.ppm / share-hidden.ppm here)"
cd "$tmp/verify-out" 2>/dev/null || { mkdir -p "$tmp/verify-out"; cd "$tmp/verify-out"; }

# nile-share-verify writes the ppm files into the cwd.
set +e
"$verify"
rc=$?
set -e

if [ -f share-visible.ppm ]; then
    cp share-visible.ppm share-hidden.ppm "$root/" 2>/dev/null || true
    echo
    echo "==> frames copied to $root/"
fi

echo
echo "==> compositor log tail"
tail -n 40 "$tmp/nile.log" || true

if [ "$rc" -eq 0 ]; then
    echo
    echo "ALL CHECKS PASSED"
else
    echo
    echo "CHECKS FAILED (exit $rc)"
fi
exit "$rc"