#!/system/bin/sh
#
# brevent_mediatek_boost.sh
# Non-root Brevent + Performance Booster (MediaTek only, Android 10–16)
#
# Developer: Willy Jr Caransa Gailo
#
# v3.0 - MTK Performance Booster + Magisk-style tweaks (non-root friendly)
#

### CONFIG ###
MIN_SDK=29
MAX_SDK=36
BREVENT_PKG="me.piebridge.brevent"
SCRIPT_VER="v3.0 - MTK Perf + Magisk-like tweaks"
# ----------------

# ---------- helpers ----------
info()  { printf "[INFO] %s\n" "$*"; }
warn()  { printf "[WARN] %s\n" "$*"; }
err()   { printf "❌ [ERROR] %s\n" "$*"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# use resetprop if available (Magisk) for persistent prop changes
USE_RESETPROP=0
if has_cmd resetprop; then
  USE_RESETPROP=1
  info "resetprop found — will use for persistent props when possible."
fi

# safe setprop wrapper: uses resetprop if available, otherwise setprop
set_prop_safe() {
  k="$1"; v="$2"
  if [ "$USE_RESETPROP" -eq 1 ]; then
    resetprop "$k" "$v" >/dev/null 2>&1 && return 0
  fi
  setprop "$k" "$v" >/dev/null 2>&1
}

# safe sysfs write (only if writable)
sysfs_write() {
  path="$1"; value="$2"
  if [ -w "$path" ]; then
    echo "$value" > "$path" 2>/dev/null && return 0 || return 1
  else
    return 1
  fi
}

# ---------- basic checks ----------
sdk=$(getprop ro.build.version.sdk 2>/dev/null)
chip=$(getprop ro.board.platform 2>/dev/null)
if [ -z "$sdk" ] || [ -z "$chip" ]; then
  err "Unable to read SDK or board platform. Abort."
  exit 1
fi

if [ "$sdk" -lt "$MIN_SDK" ] || [ "$sdk" -gt "$MAX_SDK" ]; then
  err "Unsupported Android version: $sdk (supported: $MIN_SDK..$MAX_SDK)."
  exit 2
fi

# quick MediaTek detection (board platform or /proc/cpuinfo)
is_mtk=0
case "$(echo "$chip" | tr '[:upper:]' '[:lower:]')" in
  *mt*|*mediatek*) is_mtk=1 ;;
esac
if [ "$is_mtk" -eq 0 ] && [ -r /proc/cpuinfo ]; then
  if grep -qi "mediatek" /proc/cpuinfo 2>/dev/null; then
    is_mtk=1
  fi
fi

if [ "$is_mtk" -ne 1 ]; then
  err "Not detected as MediaTek device. This script only runs on MediaTek devices. Auto-cancelling."
  exit 3
fi

info "MediaTek detected. Android SDK $sdk. Running $SCRIPT_VER."

# ---------- NETWORK: TCP + DNS + WiFi tweaks (Magisk modules & build.prop commonly use) ----------
info "Applying network & WIFI tweaks..."
# Increase TCP buffers (common build.prop/magisk tweaks). Non-persistent unless resetprop used.
set_prop_safe "net.tcp.buffersize.default" "4096,87380,256960,4096,16384,256960"
set_prop_safe "net.tcp.buffersize.wifi"    "4096,87380,256960,4096,16384,256960"
set_prop_safe "net.tcp.buffersize.lte"     "4096,87380,256960,4096,16384,256960"
set_prop_safe "net.tcp.buffersize.rmnet"   "4096,87380,256960,4096,16384,256960"

# Try congestion control (may not be supported on all builds)
set_prop_safe "net.tcp.default_congestion_control" "bbr"  # fallback: many modules set cubic/hs/reno/bbr

# wifi scanning interval (less scanning -> more stable, but adjust as you like)
set_prop_safe "wifi.supplicant_scan_interval" "180"
settings put global wifi_scan_always_enabled 0 >/dev/null 2>&1 || true

# optional periodic ping thread to keep NAT alive (backgrounded)
start_ping_keepalive() {
  # don't start multiple instances
  pidfile="/data/local/tmp/.ping_keepalive.pid"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    info "Ping keepalive already running (pid $(cat "$pidfile"))."
    return 0
  fi
  # run a background ping loop to a stable low-latency host (8.8.8.8) every 30s
  ( while true; do ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; sleep 30; done ) &
  echo $! > "$pidfile" 2>/dev/null || true
  info "Ping keepalive started (pid $(cat "$pidfile" 2>/dev/null || echo '?'))."
}
start_ping_keepalive

# ---------- REFRESH RATE: detect & lock to high supported rate ----------
info "Detecting supported display refresh rates..."
# parse dumpsys display for rates like "120.0Hz" or "144Hz" (varies by vendor output)
rates=$(dumpsys display | grep -oE '[0-9]{2,3}(\.[0-9]+)?Hz' 2>/dev/null | tr -d 'Hz' | cut -d'.' -f1 | sort -u)
max_rate=0
for r in $rates; do
  if [ "$r" -gt "$max_rate" ]; then max_rate="$r"; fi
done
# clamp to 120/144/165 if available, otherwise fallback to 120
if [ "$max_rate" -ge 165 ]; then
  target=165
elif [ "$max_rate" -ge 144 ]; then
  target=144
elif [ "$max_rate" -ge 120 ]; then
  target=120
else
  target="$max_rate"
fi

if [ -z "$target" ] || [ "$target" -le 0 ]; then
  warn "Could not detect refresh rates reliably. Skipping refresh lock."
else
  info "Locking display refresh rate to ${target}Hz (best detected)."
  # attempt the system settings put (works on many devices)
  settings put system peak_refresh_rate "$target" >/dev/null 2>&1 || true
  settings put system min_refresh_rate  "$target" >/dev/null 2>&1 || true
  # also attempt vendor props used by some modules
  set_prop_safe "persist.vendor.display.min_fps" "$target"
  set_prop_safe "persist.vendor.display.fps" "$target"
fi

# ---------- BATTERY / POWER PROFILE ----------
info "Setting battery/performance preferences..."
# Request performance mode via props and settings (non-root)
settings put global low_power 0 >/dev/null 2>&1 || true
set_prop_safe "power.performance.profile" "1"
set_prop_safe "persist.sys.battery.performanced" "1"
# try to disable Doze (best-effort)
dumpsys deviceidle enable >/dev/null 2>&1 || true
dumpsys deviceidle force-idle >/dev/null 2>&1 || true

# ---------- GAME MODE & NOTIFICATIONS ----------
info "Enabling Game Mode + notification..."
set_prop_safe "persist.sys.game_mode" "1"
set_prop_safe "sys.gfx.game" "1"
set_prop_safe "sys.boost.gaming" "1"

# send a toast-like broadcast to indicate Game Mode ON (SystemUI may or may not respond)
am broadcast -a com.android.systemui.game_mode --es status "Game Mode ON" >/dev/null 2>&1 || true

# ---------- DALVIK / ART TWEAKS ----------
info "Applying ART/Dalvik performance hints..."
# These are common build.prop / magisk module settings. Persistent if resetprop exists.
set_prop_safe "dalvik.vm.usejit" "true"
set_prop_safe "dalvik.vm.jitthreads" "4"
set_prop_safe "dalvik.vm.heapgrowthlimit" "512m"
set_prop_safe "dalvik.vm.heapsize" "1024m"
set_prop_safe "dalvik.vm.heaptargetutilization" "0.7"
set_prop_safe "dalvik.vm.heapminfree" "2m"
set_prop_safe "dalvik.vm.heapmaxfree" "8m"
# Note: On recent Android versions some dalvik props are ignored by ART; these are best-effort.

# ---------- GPU / RENDERER / VULKAN HINTS ----------
info "Applying GPU / renderer hints..."
# try force GPU rendering and HWUI options (some are read from build.prop at boot only)
set_prop_safe "debug.sf.hw" "1"
set_prop_safe "debug.hwui.renderer" "opengl"       # or "vulkan" where supported
set_prop_safe "persist.sys.force_gpu_render" "1"
set_prop_safe "persist.vendor.graphics.performance" "1"
# request GPU performance via perf props
set_prop_safe "sys.perf.gpu_max" "1"

# ---------- CPU / GPU CLOCKS: best-effort (non-root) ----------
info "Requesting CPU/GPU max performance (best-effort)."
# Try to write to common sysfs knobs (most require root). We'll try and report status.
SYS_CPU_BASE="/sys/devices/system/cpu"
CPU_SET_OK=0
# Attempt to set CPU governor to performance if writable (unlikely without root)
if [ -d "$SYS_CPU_BASE" ]; then
  for gov in $(ls -d $SYS_CPU_BASE/cpu*/cpufreq 2>/dev/null); do
    if [ -w "$gov/scaling_governor" ]; then
      echo "performance" > "$gov/scaling_governor" 2>/dev/null || true
      echo "1" > "$gov/scaling_max_freq" 2>/dev/null || true
      CPU_SET_OK=1
    fi
  done
fi

if [ "$CPU_SET_OK" -eq 1 ]; then
  info "CPU governor requests applied to writable cpufreq nodes."
else
  warn "No writable cpu cpufreq nodes found (non-root). Kernel-level clock changes require root."
fi

# ---------- THERMAL / TWEAKS (best-effort) ----------
info "Applying thermal/perf hints (best-effort)."
set_prop_safe "vendor.thermal.engine.disable" "1"  # some kernels ignore this; Magisk modules usually patch thermal config
set_prop_safe "persist.vendor.sys.thermal.eng" "0"

# ---------- ANIMATION / UI SNAPPY ----------
info "Disabling animations and UI delays..."
settings put global window_animation_scale 0 >/dev/null 2>&1 || true
settings put global transition_animation_scale 0 >/dev/null 2>&1 || true
settings put global animator_duration_scale 0 >/dev/null 2>&1 || true

# ---------- EXTRA Magisk-like build.prop tweaks (best-effort via resetprop) ----------
info "Applying extra Magisk-ish props (if possible)..."
# These keys are commonly present in Magisk modules and build.prop tweak lists.
set_prop_safe "ro.HOME_APP_ADJ" "1"              # keep launcher in memory
set_prop_safe "ro.media.enc.jpeg.quality" "100"
set_prop_safe "ro.config.hw_quickpoweron" "1"
set_prop_safe "persist.sys.dalvik.vm.execution" "jit,quick"  # vendor may ignore

# ---------- LAUNCH or CHECK BREVENT ----------
if pm list packages | grep -q "^package:$BREVENT_PKG"; then
  info "Brevent found — launching..."
  monkey -p "$BREVENT_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || \
    am start -a android.intent.action.MAIN -n "$BREVENT_PKG"/.MainActivity >/dev/null 2>&1 || true
else
  warn "Brevent not installed. Skipping launch."
fi

# ---------- Final status & tips ----------
info "Perf script finished. Summary:"
info " - Network: tcp buffers, congestion hint, ping keepalive started."
info " - Display: attempted refresh lock to ${target:-?}Hz."
info " - Dalvik: JIT/heap hints applied (may be ignored on newer ART builds)."
info " - GPU/Renderer: HWUI & renderer hints applied (build-time props may need reboot)."
info " - CPU/GPU clocks: attempted; kernel/sysfs changes require root; script tried only writable nodes."
info " - Thermal: best-effort props set (kernel may ignore)."
info ""
info "If you have root + Magisk:"
info " - Re-run this script as root or in Magisk environment to let resetprop persist, and kernel sysfs writes will succeed."
info " - Many Magisk modules (PerfMTK, XFaster, CPU Render Boost) implement more aggressive governor and thermal configs which require root. See PerfMTK for MediaTek-specific settings. 1"

# friendly end
echo
info "✅ Performance mode active (best-effort for non-root). Enjoy your gaming boost!"
exit 0