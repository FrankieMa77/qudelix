#!/bin/bash
set -euo pipefail

SRC="${QUDELIX_SRC:-$HOME/qudelix-port}"
OUT="${1:-$HOME/qudelix-renders}"
IMAGE="${QUDELIX_APP_IMAGE:-qudelix-app-build}"
VOLUME="${QUDELIX_APP_VOLUME:-qudelix-app-render}"

mkdir -p "$OUT"
docker run --rm --init \
  --tmpfs /tmp:rw,exec,size=2g \
  -e QUDELIX_APP=1 \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -e RENDER_SET="${RENDER_SET:-all}" \
  -v "$SRC:/src" \
  -v "$OUT:/out" \
  -v "$VOLUME:/build" \
  -w /src/QudelixBar \
  "$IMAGE" \
  bash -c '
    set -euo pipefail
    swift build --product qudelix-app --scratch-path /build 2>&1 | tail -3
    render() {
      local name="$1" page="$2" theme="$3" size="$4"
      shift 4
      local flag=""
      [ "$theme" = "dark" ] && flag="--dark"
      xvfb-run -a -s "-screen 0 1280x1400x24" \
        env GSK_RENDERER=cairo GDK_BACKEND=x11 GTK_A11Y=none \
        /build/debug/qudelix-app --render-page "$page" --render-out "/out/$name-$theme-$size.png" $flag --size "$size" "$@" \
        2>/dev/null
    }
    if [ "$RENDER_SET" = "all" ]; then
    for page in device eq presets library tune stage level; do
      for theme in light dark; do
        render "$page" "$page" "$theme" 900x640 --no-device
      done
    done
    render eq eq light 360x640 --no-device
    render eq eq dark 360x640 --no-device
    for theme in light dark; do
      render device-demo device "$theme" 900x640 --demo
      render device-demo device "$theme" 360x640 --demo
    done
    render device-charging device light 900x640 --demo --power charging
    render device-charging device dark 360x640 --demo --power idle
    render device-searching device light 900x640 --no-device
    render device-demo-tall device light 900x1150 --demo
    render device-demo-tall device dark 900x1150 --demo
    for theme in light dark; do
      for size in 900x640 360x640; do
        render eq-demo eq "$theme" "$size" --demo
        render presets-demo presets "$theme" "$size" --demo
      done
    done
    render eq-selected eq light 900x640 --demo --select-band 4
    render eq-selected eq dark 360x640 --demo --select-band 12
    render eq-tall eq light 360x1300 --demo --select-band 2
    for size in 900x640 360x640; do
      render presets-save presets light "$size" --demo --dialog save
      render presets-rename presets light "$size" --demo --dialog rename
    done
    for theme in light dark; do
      for size in 900x640 360x640; do
        render library-saved library "$theme" "$size" --demo --section saved
        render library-saved-selected library "$theme" "$size" --demo --section saved --select 0
        render library-autoeq library "$theme" "$size" --demo --section autoeq
        render library-autoeq-selected library "$theme" "$size" --demo --section autoeq --query "HD 6" --select 0
        render library-ai library "$theme" "$size" --demo --section ai
        render library-ai-result library "$theme" "$size" --demo --section ai --ai-draft
      done
    done
    for theme in light dark; do
      render library-saved-tall library "$theme" 360x1100 --demo --section saved --select 0
      render library-autoeq-tall library "$theme" 360x1500 --demo --section autoeq --query "HD 6" --select 0
      render library-ai-tall library "$theme" 360x2000 --demo --section ai --ai-draft
      render library-delete library "$theme" 900x640 --demo --section saved --dialog delete
      render library-delete library "$theme" 360x640 --demo --section saved --dialog delete
    done
    render library-name library light 360x640 --demo --section saved --dialog name
    render library-forget library light 360x640 --demo --section ai --ai-draft --dialog forget
    render library-offline library light 900x640 --no-device --section saved --select 0
    render library-offline library dark 360x640 --no-device --section autoeq
    for theme in light dark; do
      render app-menu device "$theme" 900x640 --demo --open-menu
      render about device "$theme" 900x640 --demo --dialog about
      render about device "$theme" 360x640 --demo --dialog about
    done
    render app-menu device light 360x640 --demo --open-menu
    render device-battery-tall device light 360x1000 --demo
    render device-battery-tall device dark 360x1000 --demo
    for theme in light dark; do
      for size in 900x640 360x640; do
        render eq-loading eq "$theme" "$size" --demo --eq-state loading
        render eq-failed eq "$theme" "$size" --demo --eq-state failed
        render toast-success presets "$theme" "$size" --demo --toast success
        render toast-failure device "$theme" "$size" --demo --toast failure
      done
    done
    mkdir -p /tmp/autostart-on/autostart
    printf "[Desktop Entry]\nType=Application\nName=Qudelix\nExec=qudelix-app --hidden\n" > /tmp/autostart-on/autostart/io.github.FrankieMa77.Qudelix.desktop
    for theme in light dark; do
      flag=""
      [ "$theme" = "dark" ] && flag="--dark"
      for size in 900x640 360x640; do
        xvfb-run -a -s "-screen 0 1280x1400x24" \
          env XDG_CONFIG_HOME=/tmp/autostart-on GSK_RENDERER=cairo GDK_BACKEND=x11 GTK_A11Y=none \
          /build/debug/qudelix-app --render-page device --render-out "/out/app-menu-autostart-on-$theme-$size.png" $flag --size "$size" --demo --open-menu \
          2>/dev/null
      done
    done
    fi
    for theme in light dark; do
      render nav-wide device "$theme" 900x640 --demo
      render nav-narrow device "$theme" 360x640 --demo --sidebar
      render nav-narrow-content eq "$theme" 360x640 --demo
      for size in 900x640 360x640; do
        render eq-ghost eq "$theme" "$size" --demo --ghost
        render eq-following eq "$theme" "$size" --demo --follow
        render presets-custom presets "$theme" "$size" --demo --custom-eq
        render eq-no-audio eq "$theme" "$size" --demo --no-audio
        render stage-placeholder stage "$theme" "$size" --demo
        render level-no-audio level "$theme" "$size" --demo --no-audio
      done
      render eq-ghost-tall eq "$theme" 360x1700 --demo --ghost
      render eq-following-tall eq "$theme" 360x1700 --demo --follow
      render eq-ghost-wide eq "$theme" 900x1500 --demo --ghost
      render eq-following-wide eq "$theme" 900x1500 --demo --follow
    done
    /build/debug/qudelix-app --version
    /build/debug/qudelix-app --help
    dump_tray() {
      xvfb-run -a -s "-screen 0 1280x1400x24" \
        env GSK_RENDERER=cairo GDK_BACKEND=x11 GTK_A11Y=none \
        /build/debug/qudelix-app --dump-tray "/out/$1" "${@:2}" 2>/dev/null
    }
    dump_tray tray-connected.txt --demo
    dump_tray tray-charging.txt --demo --power charging
    dump_tray tray-disconnected.txt --no-device
    chown -R "$HOST_UID:$HOST_GID" /out
  '
ls -l "$OUT"
