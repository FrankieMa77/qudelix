#!/bin/sh
set -u

if [ -z "${QX_HARNESS_BUS:-}" ]; then
    QX_HARNESS_BUS=1
    export QX_HARNESS_BUS
    exec dbus-run-session -- "$0" "$@"
fi

here=$(cd "$(dirname "$0")" && pwd)
package_root="$here/../../QudelixBar"
root=$(mktemp -d /tmp/qx-pipewire.XXXXXX)
export HOME="$root/home"
export XDG_RUNTIME_DIR="$root/run"
export XDG_CONFIG_HOME="$root/config"
export XDG_STATE_HOME="$root/state"
export XDG_DATA_HOME="$root/data"
export XDG_CACHE_HOME="$root/cache"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME/pipewire/pipewire.conf.d" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
chmod 700 "$XDG_RUNTIME_DIR"

cat > "$XDG_CONFIG_HOME/pipewire/pipewire.conf.d/10-qudelix-test-sinks.conf" <<'CONF'
context.objects = [
    {
        factory = adapter
        args = {
            factory.name = support.null-audio-sink
            node.name = "qx_test_5k"
            node.description = "Qudelix 5K Test"
            media.class = Audio/Sink
            audio.position = [ FL FR ]
            device.api = alsa
            device.bus = usb
            device.vendor.id = "0x0a12"
            device.product.id = "0x4007"
            object.linger = true
        }
    }
    {
        factory = adapter
        args = {
            factory.name = support.null-audio-sink
            node.name = "qx_test_other"
            node.description = "Second Output Test"
            media.class = Audio/Sink
            audio.position = [ FL FR ]
            device.api = alsa
            device.bus = pci
            object.linger = true
        }
    }
    {
        factory = adapter
        args = {
            factory.name = support.null-audio-sink
            node.name = "qx_test_loopback"
            node.description = "Loopback Output Test"
            media.class = Audio/Sink
            audio.position = [ FL FR ]
            device.id = 777
            priority.session = 1
            priority.driver = 1
            object.linger = true
        }
    }
    {
        factory = adapter
        args = {
            factory.name = support.null-audio-sink
            node.name = "qx_test_internal"
            node.description = "Internal Output Test"
            media.class = Audio/Sink/Internal
            audio.position = [ FL FR ]
            device.id = 777
            api.bluez5.profile = "headset-head-unit"
            priority.session = 1
            priority.driver = 1
            object.linger = true
        }
    }
]
CONF

pipewire > "$root/pipewire.log" 2>&1 &
pipewire_pid=$!
wireplumber > "$root/wireplumber.log" 2>&1 &
wireplumber_pid=$!

cleanup() {
    kill "$wireplumber_pid" "$pipewire_pid" 2>/dev/null
    wait "$wireplumber_pid" "$pipewire_pid" 2>/dev/null
    rm -rf "$root"
}
trap cleanup EXIT INT TERM

ready=0
i=0
while [ "$i" -lt 150 ]; do
    if pw-metadata -n default 2>/dev/null | grep -q 'default.audio.sink' \
        && pw-cli ls Node 2>/dev/null | grep -q qx_test_other \
        && pw-cli ls Node 2>/dev/null | grep -q qx_test_5k; then
        ready=1
        break
    fi
    i=$((i + 1))
    sleep 0.2
done

if [ "$ready" -ne 1 ]; then
    echo "PipeWire harness did not come up" >&2
    tail -n 30 "$root/pipewire.log" "$root/wireplumber.log" >&2
    exit 1
fi

cd "$package_root" || exit 1
if [ -n "${QX_HARNESS_COMMAND:-}" ]; then
    sh -c "$QX_HARNESS_COMMAND"
    exit $?
fi
scratch=""
if [ -n "${QX_SCRATCH_PATH:-}" ]; then
    scratch="--scratch-path $QX_SCRATCH_PATH"
fi
QX_PIPEWIRE_HARNESS=1 QUDELIX_APP=1 swift test $scratch --filter QudelixAudioTests "$@"
status=$?
exit "$status"
