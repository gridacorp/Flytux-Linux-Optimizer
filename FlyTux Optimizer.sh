#!/usr/bin/env bash
#=============================================================================
# 🐧 FlyTux Optimizer v19.0 - Edición "Sistema Cognitivo Cooperativo"
# Cambios críticos vs v18.0:
#  • Detección CPU por DMI product_name (no por model numérico)
#  • TJmax leído de hwmon (no heurística)
#  • Modo cooperativo con TLP/PPD/thermald (no pelea)
#  • Udev rule para energía (no path unit rota)
#  • UUID basado en hardware real (DMI + machine-id)
#  • Histéresis de 120s para evitar oscilaciones
#  • Renombrado telemetry → history (100% local, sin red)
#  • Sistema de puntuación del hardware
#  • Perfiles de comportamiento (developer/gaming/office/battery/silent)
#=============================================================================

set -Eeuo pipefail
trap 'echo "❌ Error en línea $LINENO: $BASH_COMMAND" >&2' ERR

# ═══════════════════════════════════════════════════════════════════════════
# FUNCIONES AUXILIARES
# ═══════════════════════════════════════════════════════════════════════════

install_or_upgrade() {
  local DESC="$1"; shift
  local PKGS=("$@")
  [ ${#PKGS[@]} -eq 0 ] && return
  echo "   📦 $DESC: procesando ${#PKGS[@]} paquetes..."
  apt install -y "${PKGS[@]}" 2>/dev/null || true
}

pkg_exists() { apt-cache madison "$1" 2>/dev/null | grep -q '|'; }

enable_service() {
  local SERVICE="$1"
  if systemctl list-unit-files "${SERVICE}.service" 2>/dev/null | grep -q "${SERVICE}.service"; then
    systemctl enable --now "$SERVICE" 2>/dev/null || true
  fi
}

disable_service() {
  local SERVICE="$1"
  if systemctl list-unit-files "${SERVICE}.service" 2>/dev/null | grep -q "${SERVICE}.service"; then
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    echo "   🔕 Servicio '$SERVICE' desactivado."
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# 0. VALIDACIÓN INICIAL
# ═══════════════════════════════════════════════════════════════════════════

echo "🐧 FlyTux Optimizer v19.0 - Sistema Cognitivo Cooperativo | $(date)"
[ "$(id -u)" -ne 0 ] && { echo "❌ Ejecutar como: sudo bash $0"; exit 1; }

. /etc/os-release
if [[ ! "$ID_LIKE" =~ (debian|ubuntu) ]] && [[ ! "$ID" =~ (debian|ubuntu|linuxmint|pop|zorin) ]]; then
    echo "❌ Solo compatible con Debian/Ubuntu/Linux Mint/Pop!_OS/Zorin OS"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/flytux-$(date +%F-%H%M).log"
BACKUP="/var/backups/flytux-etc-$(date +%F).tar.gz"
FLYTUX_CONF="/etc/flytux"
FLYTUX_LIB="/usr/lib/flytux"
FLYTUX_VAR="/var/lib/flytux"
FLYTUX_SHARE="/usr/share/flytux"
mkdir -p /var/backups "$FLYTUX_CONF" "$FLYTUX_LIB/modules" \
         "$FLYTUX_VAR/history" "$FLYTUX_VAR/behavior" \
         "$FLYTUX_SHARE/hardware"
exec > >(tee -a "$LOG") 2>&1

echo "📦 Backup: $BACKUP | 📜 Logs: $LOG"
echo "🏗️  Construyendo sistema cognitivo cooperativo..."

# ═══════════════════════════════════════════════════════════════════════════
# 1-2. BACKUP Y REPOSITORIOS
# ═══════════════════════════════════════════════════════════════════════════

echo ""; echo "🔐 [1/17] Backup persistente..."
tar czf "$BACKUP" /etc/sysctl.d /etc/default /etc/systemd/system /etc/udev/rules.d \
    /etc/modprobe.d /etc/apt/sources.list /etc/apt/sources.list.d/ /etc/apt/sources.sources \
    /etc/flytux /usr/lib/flytux 2>/dev/null || true
[ -f "$BACKUP" ] && echo "✅ Backup: $(du -sh "$BACKUP" | awk '{print $1}')"

echo ""; echo "🔓 [2/17] Repositorios..."
enable_deb822_nonfree() {
  local FILE="$1"; [ -f "$FILE" ] || return
  if grep -q "^Components:" "$FILE" && ! grep -q "non-free" "$FILE"; then
    sed -i '/^Components:/ s/$/ non-free non-free-firmware/' "$FILE" 2>/dev/null || true
  fi
}
enable_legacy_nonfree() {
  local FILE="$1"; [ -f "$FILE" ] || return
  local CODENAME=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2)
  for REPO in "contrib" "non-free" "non-free-firmware"; do
    if ! grep -q "$REPO" "$FILE"; then
      sed -i "s/^\(deb .*\)$CODENAME\(.*\)$/\1$CODENAME\2 $REPO/" "$FILE" 2>/dev/null || true
    fi
  done
}

if [[ "$ID" == "debian" ]] || [[ "$ID_LIKE" == *"debian"* ]]; then
  for FILE in /etc/apt/sources.list.d/*.sources /etc/apt/sources.sources; do enable_deb822_nonfree "$FILE"; done
  enable_legacy_nonfree "/etc/apt/sources.list"
else
  for FILE in /etc/apt/sources.list.d/*.sources /etc/apt/sources.sources; do enable_deb822_nonfree "$FILE"; done
  enable_legacy_nonfree "/etc/apt/sources.list"
  command -v add-apt-repository &>/dev/null && { add-apt-repository multiverse -y >/dev/null 2>&1; add-apt-repository restricted -y >/dev/null 2>&1; } || true
fi

apt update -o Acquire::Retries=3 --allow-releaseinfo-change -y >/dev/null 2>&1 || true
echo "✅ Repositorios listos"

# ═══════════════════════════════════════════════════════════════════════════
# 3. DETECCIÓN AVANZADA DE HARDWARE (MEJORADA)
# ═══════════════════════════════════════════════════════════════════════════

echo ""; echo "🔍 [3/17] Diagnóstico avanzado..."
RAM_MB=$(awk '/MemTotal/ {printf "%d",$2/1024}' /proc/meminfo)
SWAP_TOTAL=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
HAS_SWAP=$([ "$SWAP_TOTAL" -gt 0 ] && echo "true" || echo "false")

IS_LAPTOP="false"
ls /sys/class/power_supply/BAT* >/dev/null 2>&1 && IS_LAPTOP="true"

BOOT_MODE="bios"
[ -d /sys/firmware/efi ] && BOOT_MODE="uefi"

SECURE_BOOT="unknown"
if command -v mokutil &>/dev/null; then
  mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled" && SECURE_BOOT="enabled"
  mokutil --sb-state 2>/dev/null | grep -q "SecureBoot disabled" && SECURE_BOOT="disabled"
fi

# ─────────────────────────────────────────────────────────────────────────
# DETECCIÓN DE CPU MEJORADA: DMI product_name + lscpu (no solo model numérico)
# ─────────────────────────────────────────────────────────────────────────
CPU_VENDOR=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
CPU_CORES=$(nproc)
CPU_FAMILY=$(grep -m1 "cpu family" /proc/cpuinfo | awk '{print $4}')
CPU_MODEL_NUM=$(grep -m1 "^model[[:space:]]*:" /proc/cpuinfo | awk '{print $3}')
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)

# Leer DMI product_name para identificación real del equipo
DMI_PRODUCT_NAME="unknown"
[ -f /sys/class/dmi/id/product_name ] && DMI_PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null | xargs)

# Detectar generación y TJmax usando el NOMBRE COMERCIAL de la CPU
CPU_GEN="unknown"
CPU_TJMAX="auto"  # "auto" significa: leer del hardware

if [[ "$CPU_VENDOR" == *"intel"* ]]; then
  # Intel: usar el nombre comercial para identificar generación
  if echo "$CPU_MODEL" | grep -qiE "core ultra 9|core ultra 7|core ultra 5"; then
    if echo "$CPU_MODEL" | grep -qi "series 2"; then
      CPU_GEN="Lunar Lake / Arrow Lake"
      CPU_TJMAX=105
    else
      CPU_GEN="Meteor Lake"
      CPU_TJMAX=105
    fi
  elif echo "$CPU_MODEL" | grep -qi "14th"; then
    CPU_GEN="Raptor Lake Refresh (14th)"
    CPU_TJMAX=100
  elif echo "$CPU_MODEL" | grep -qi "13th"; then
    CPU_GEN="Raptor Lake (13th)"
    CPU_TJMAX=100
  elif echo "$CPU_MODEL" | grep -qi "12th"; then
    CPU_GEN="Alder Lake (12th)"
    CPU_TJMAX=100
  elif echo "$CPU_MODEL" | grep -qi "11th"; then
    CPU_GEN="Tiger Lake (11th)"
    CPU_TJMAX=100
  elif echo "$CPU_MODEL" | grep -qiE "10th|core i[3579]-10"; then
    CPU_GEN="Ice/Comet Lake (10th)"
    CPU_TJMAX=100
  fi
elif [[ "$CPU_VENDOR" == *"amd"* ]]; then
  # AMD: usar family + model name para Zen
  if echo "$CPU_MODEL" | grep -qiE "9[0-9]{3}|7[89][0-9]{2}|AI [0-9]+"; then
    CPU_GEN="Zen 5"
    CPU_TJMAX=95
  elif echo "$CPU_MODEL" | grep -qiE "7[0-9]{3}|PRO 7[0-9]{3}"; then
    CPU_GEN="Zen 4"
    CPU_TJMAX=95
  elif echo "$CPU_MODEL" | grep -qiE "5[0-9]{3}|PRO 5[0-9]{3}"; then
    CPU_GEN="Zen 3"
    CPU_TJMAX=90
  elif echo "$CPU_MODEL" | grep -qiE "3[0-9]{3}|PRO 3[0-9]{3}"; then
    CPU_GEN="Zen 2"
    CPU_TJMAX=95
  else
    CPU_GEN="Zen / Zen+"
    CPU_TJMAX=95
  fi
fi

# Detección de CPU híbrida (P+E cores)
IS_HYBRID_CPU="false"
if [ -d /sys/devices/system/cpu ]; then
  CAPACITIES=$(cat /sys/devices/system/cpu/cpu*/cpu_capacity 2>/dev/null | sort -u | wc -l)
  [ "$CAPACITIES" -gt 1 ] && IS_HYBRID_CPU="true"
fi
# Fallback: detectar por nombre comercial
if [ "$IS_HYBRID_CPU" = "false" ]; then
  if echo "$CPU_MODEL" | grep -qiE "core ultra|12th|13th|14th"; then
    IS_HYBRID_CPU="true"
  fi
fi

CPU_FLAGS=$(grep -m1 "^flags" /proc/cpuinfo | tr '[:upper:]' '[:lower:]')
HAS_AES=$(echo "$CPU_FLAGS" | grep -qw "aes" && echo "true" || echo "false")
HAS_AVX2=$(echo "$CPU_FLAGS" | grep -qw "avx2" && echo "true" || echo "false")
HAS_AVX512=$(echo "$CPU_FLAGS" | grep -qw "avx512f" && echo "true" || echo "false")

# ─────────────────────────────────────────────────────────────────────────
# DISCO
# ─────────────────────────────────────────────────────────────────────────
DISK_NAME=$(lsblk -ndo pkname "$(df -P / | awk 'NR==2{print $1}')" 2>/dev/null | head -1)
DISK_TYPE="hdd"
if [ -n "$DISK_NAME" ]; then
  [ "$(cat /sys/block/$DISK_NAME/queue/rotational 2>/dev/null)" = "0" ] && DISK_TYPE="ssd"
  echo "$DISK_NAME" | grep -qi "nvme" && DISK_TYPE="nvme"
fi

SUPPORTS_TRIM="false"
if [ "$DISK_TYPE" != "hdd" ] && [ -n "$DISK_NAME" ]; then
  DISC_INFO=$(lsblk --discard "/dev/$DISK_NAME" 2>/dev/null | tail -n 1)
  echo "$DISC_INFO" | grep -qE "yes|1" && SUPPORTS_TRIM="true"
fi

# ─────────────────────────────────────────────────────────────────────────
# RAM ECC (EDAC primero, dmidecode fallback)
# ─────────────────────────────────────────────────────────────────────────
HAS_ECC="false"
if [ -d /sys/devices/system/edac/mc ]; then
  ls /sys/devices/system/edac/mc/mc*/ce_count 2>/dev/null | head -1 | grep -q "ce_count" && HAS_ECC="true"
fi
if [ "$HAS_ECC" = "false" ] && command -v dmidecode &>/dev/null; then
  dmidecode -t memory 2>/dev/null | grep -q "ECC" && HAS_ECC="true"
fi

# ─────────────────────────────────────────────────────────────────────────
# GPU (detección múltiple)
# ─────────────────────────────────────────────────────────────────────────
GPU_VENDORS=""
PRIMARY_GPU_DRIVER="unknown"
HAS_HYBRID_GPU="false"
HAS_INTEL_GPU="false"
HAS_AMD_GPU="false"
HAS_NVIDIA_GPU="false"

if command -v lspci &>/dev/null; then
  GPU_COUNT=0
  lspci -nn | grep -iE "vga|3d|display" | grep -q "\[8086:" && { GPU_VENDORS="${GPU_VENDORS}intel,"; HAS_INTEL_GPU="true"; GPU_COUNT=$((GPU_COUNT+1)); }
  lspci -nn | grep -iE "vga|3d|display" | grep -q "\[1002:" && { GPU_VENDORS="${GPU_VENDORS}amd,"; HAS_AMD_GPU="true"; GPU_COUNT=$((GPU_COUNT+1)); }
  lspci -nn | grep -iE "vga|3d|display" | grep -q "\[10de:" && { GPU_VENDORS="${GPU_VENDORS}nvidia,"; HAS_NVIDIA_GPU="true"; GPU_COUNT=$((GPU_COUNT+1)); }
  [ "$GPU_COUNT" -gt 1 ] && HAS_HYBRID_GPU="true"
  
  if command -v glxinfo &>/dev/null; then
    RENDERER=$(glxinfo 2>/dev/null | grep "OpenGL renderer string" | tr '[:upper:]' '[:lower:]')
    if echo "$RENDERER" | grep -q "intel"; then PRIMARY_GPU_DRIVER="i915"
    elif echo "$RENDERER" | grep -qE "amd|radeon"; then PRIMARY_GPU_DRIVER="amdgpu"
    elif echo "$RENDERER" | grep -q "nvidia"; then PRIMARY_GPU_DRIVER="nvidia"
    fi
  fi
  [ "$PRIMARY_GPU_DRIVER" = "unknown" ] && PRIMARY_GPU_DRIVER=$(lspci -nnk | grep -i "vga compatible controller" -A 2 | grep "Kernel driver in use:" | awk '{print $4}' | tr '[:upper:]' '[:lower:]' | head -n 1)
fi
GPU_VENDORS="${GPU_VENDORS%,}"
[ -z "$GPU_VENDORS" ] && GPU_VENDORS="unknown"

HAS_SENSORS="false"
command -v sensors &>/dev/null && sensors 2>/dev/null | grep -q "Core\|Tctl\|Package" && HAS_SENSORS="true"

HAS_BLUETOOTH="false"
lspci -nn 2>/dev/null | grep -qi "bluetooth" && HAS_BLUETOOTH="true"
[ "$HAS_BLUETOOTH" = "false" ] && lsusb 2>/dev/null | grep -qi "bluetooth" && HAS_BLUETOOTH="true"

HAS_MODEM="false"
lsusb 2>/dev/null | grep -qiE "modem|lte|4g|5g" && HAS_MODEM="true"

HAS_PRINTER="false"
lsusb 2>/dev/null | grep -qi "printer" && HAS_PRINTER="true"
lpstat -p 2>/dev/null | grep -q "printer" && HAS_PRINTER="true"

ACTIVE_USER=$(logname 2>/dev/null || who | awk '{print $1;exit}')
DE="unknown"; command -v loginctl &>/dev/null && [ -n "$ACTIVE_USER" ] && {
  S=$(loginctl list-sessions --no-legend | grep -m1 "$ACTIVE_USER" | awk '{print $1}')
  [ -n "$S" ] && DE=$(loginctl show-session "$S" -p Desktop --value 2>/dev/null || echo unknown)
}
[ -z "$DE" ] || [ "$DE" = "unknown" ] && DE="${XDG_CURRENT_DESKTOP:-unknown}"
DE=$(echo "$DE" | tr '[:upper:]' '[:lower:]')

# ─────────────────────────────────────────────────────────────────────────
# DETECCIÓN DE GESTORES DE ENERGÍA ACTIVOS (MODO COOPERATIVO)
# ─────────────────────────────────────────────────────────────────────────
ACTIVE_MANAGERS=""
systemctl is-active --quiet power-profiles-daemon 2>/dev/null && ACTIVE_MANAGERS="${ACTIVE_MANAGERS}power-profiles-daemon,"
systemctl is-active --quiet tlp 2>/dev/null && ACTIVE_MANAGERS="${ACTIVE_MANAGERS}tlp,"
systemctl is-active --quiet thermald 2>/dev/null && ACTIVE_MANAGERS="${ACTIVE_MANAGERS}thermald,"
systemctl is-active --quiet auto-cpufreq 2>/dev/null && ACTIVE_MANAGERS="${ACTIVE_MANAGERS}auto-cpufreq,"
ACTIVE_MANAGERS="${ACTIVE_MANAGERS%,}"
[ -z "$ACTIVE_MANAGERS" ] && ACTIVE_MANAGERS="none"

# Decidir modo de operación de FlyTux
FLYTUX_MODE="cooperative"  # cooperative | exclusive
if [ "$ACTIVE_MANAGERS" = "none" ]; then
  FLYTUX_MODE="exclusive"  # FlyTux controla todo
fi

echo "💾 ${RAM_MB}MB | 💻 Laptop: $IS_LAPTOP"
echo "🖥️  CPU: $CPU_MODEL"
echo "    Generación: $CPU_GEN | TJmax: ${CPU_TJMAX}°C | Híbrida: $IS_HYBRID_CPU"
echo "💿 Disco: $DISK_TYPE | 🎮 GPU: $GPU_VENDORS (Híbrida: $HAS_HYBRID_GPU)"
echo "🌡️  Sensores: $HAS_SENSORS | 📶 BT: $HAS_BLUETOOTH | 🖨️ Impresora: $HAS_PRINTER"
echo "🤝 Gestores de energía activos: $ACTIVE_MANAGERS"
echo "🎯 Modo FlyTux: $FLYTUX_MODE"

# ═══════════════════════════════════════════════════════════════════════════
# 4. UUID BASADO EN HARDWARE REAL (no aleatorio)
# ═══════════════════════════════════════════════════════════════════════════

echo ""; echo "💾 [4/17] Generando identidad única basada en hardware..."

# Combinar product_uuid (hardware) + machine-id (instalación)
# Esto sobrevive reinstalaciones del SO pero cambia si cambia el hardware
DMI_UUID="unknown"
[ -f /sys/class/dmi/id/product_uuid ] && DMI_UUID=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)
MACHINE_ID="unknown"
[ -f /etc/machine-id ] && MACHINE_ID=$(cat /etc/machine-id 2>/dev/null)

# Si ya existe un perfil, preservar el UUID (sobrevive reinstalaciones si hay backup)
EXISTING_UUID=""
[ -f "$FLYTUX_CONF/hardware-profile.json" ] && \
  EXISTING_UUID=$(grep -o '"uuid": *"[^"]*"' "$FLYTUX_CONF/hardware-profile.json" 2>/dev/null | cut -d'"' -f4)

if [ -n "$EXISTING_UUID" ]; then
  DEVICE_UUID="$EXISTING_UUID"
  FIRST_DETECTED=$(grep -o '"first_detected": *"[^"]*"' "$FLYTUX_CONF/hardware-profile.json" 2>/dev/null | cut -d'"' -f4)
  [ -z "$FIRST_DETECTED" ] && FIRST_DETECTED=$(date -Iseconds)
else
  # Generar UUID determinista basado en hardware
  DEVICE_UUID=$(echo -n "${DMI_UUID}-${MACHINE_ID}" | sha256sum | cut -c1-32 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-4\3-8\4-\5/')
  FIRST_DETECTED=$(date -Iseconds)
fi
LAST_UPDATE=$(date -Iseconds)

echo "✅ UUID: $DEVICE_UUID"
echo "   Primera detección: $FIRST_DETECTED"

# ═══════════════════════════════════════════════════════════════════════════
# 5. PERFIL PERSISTENTE
# ═══════════════════════════════════════════════════════════════════════════

echo ""; echo "💾 [5/17] Guardando perfil persistente..."

cat > "$FLYTUX_CONF/hardware-profile.json" <<EOF
{
  "version": "19.0",
  "device": {
    "uuid": "$DEVICE_UUID",
    "first_detected": "$FIRST_DETECTED",
    "last_update": "$LAST_UPDATE",
    "product_name": "$DMI_PRODUCT_NAME"
  },
  "distro": {"id": "$ID", "version": "$VERSION_ID"},
  "cpu": {
    "vendor": "$CPU_VENDOR",
    "model": "$CPU_MODEL",
    "generation": "$CPU_GEN",
    "family": $CPU_FAMILY,
    "model_num": $CPU_MODEL_NUM,
    "cores": $CPU_CORES,
    "hybrid": $IS_HYBRID_CPU,
    "aes": $HAS_AES,
    "avx2": $HAS_AVX2,
    "avx512": $HAS_AVX512,
    "tjmax": "$CPU_TJMAX"
  },
  "memory": {
    "ram_mb": $RAM_MB,
    "ecc": $HAS_ECC,
    "swap_kb": $SWAP_TOTAL
  },
  "storage": {
    "primary": "$DISK_NAME",
    "type": "$DISK_TYPE",
    "trim": $SUPPORTS_TRIM
  },
  "gpu": {
    "vendors": "$GPU_VENDORS",
    "intel": $HAS_INTEL_GPU,
    "amd": $HAS_AMD_GPU,
    "nvidia": $HAS_NVIDIA_GPU,
    "hybrid": $HAS_HYBRID_GPU,
    "primary_driver": "$PRIMARY_GPU_DRIVER"
  },
  "peripherals": {
    "bluetooth": $HAS_BLUETOOTH,
    "modem": $HAS_MODEM,
    "printer": $HAS_PRINTER,
    "thermal_sensors": $HAS_SENSORS
  },
  "system": {
    "form_factor": "$([ "$IS_LAPTOP" = "true" ] && echo "laptop" || echo "desktop")",
    "boot_mode": "$BOOT_MODE",
    "secure_boot": "$SECURE_BOOT",
    "desktop": "$DE",
    "user": "$ACTIVE_USER"
  },
  "power_managers": {
    "active": "$ACTIVE_MANAGERS",
    "flytux_mode": "$FLYTUX_MODE"
  }
}
EOF
chmod 644 "$FLYTUX_CONF/hardware-profile.json"
echo "✅ Perfil guardado en $FLYTUX_CONF/hardware-profile.json"

# ═══════════════════════════════════════════════════════════════════════════
# 6. HAL MEJORADO (TJmax desde hwmon + histéresis)
# ═══════════════════════════════════════════════════════════════════════════

echo ""; echo "🏗️  [6/17] Construyendo HAL con lectura real de hwmon..."

# Módulo CPU (con histéresis)
cat > "$FLYTUX_LIB/modules/cpu.sh" <<'EOF'
#!/usr/bin/env bash
# FlyTux HAL - Módulo CPU
# Aplica cambios de governor con histéresis para evitar oscilaciones

STATE_FILE="/var/lib/flytux/history/cpu-state"
HYSTERESIS_SECONDS=120

set_governor() {
  local REQUESTED="$1"
  local NOW=$(date +%s)
  
  # Leer estado actual
  local LAST_PROFILE="unknown"
  local LAST_CHANGE=0
  if [ -f "$STATE_FILE" ]; then
    LAST_PROFILE=$(cut -d'|' -f1 "$STATE_FILE" 2>/dev/null)
    LAST_CHANGE=$(cut -d'|' -f2 "$STATE_FILE" 2>/dev/null)
  fi
  
  # Si el perfil es el mismo, no hacer nada
  if [ "$LAST_PROFILE" = "$REQUESTED" ]; then
    return 0
  fi
  
  # Histéresis: esperar HYSTERESIS_SECONDS antes de cambiar
  local ELAPSED=$((NOW - LAST_CHANGE))
  if [ "$ELAPSED" -lt "$HYSTERESIS_SECONDS" ]; then
    logger -t flytux "CPU: cambio '$LAST_PROFILE' → '$REQUESTED' pospuesto (${ELAPSED}s/${HYSTERESIS_SECONDS}s histéresis)"
    return 0
  fi
  
  # Aplicar el cambio
  local GOV=""
  case "$REQUESTED" in
    performance) GOV="performance" ;;
    balanced)    GOV="schedutil" ;;
    powersave)   GOV="powersave" ;;
    silent)      GOV="powersave" ;;
    *)           GOV="schedutil" ;;
  esac
  
  if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]; then
    if grep -q "$GOV" /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors; then
      echo "$GOV" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
      echo "${REQUESTED}|${NOW}" > "$STATE_FILE"
      logger -t flytux "CPU governor: $GOV (perfil: $REQUESTED)"
    fi
  fi
}

case "$1" in
  set-governor) set_governor "$2" ;;
  get-current) cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown" ;;
esac
EOF
chmod +x "$FLYTUX_LIB/modules/cpu.sh"

# Módulo GPU
cat > "$FLYTUX_LIB/modules/gpu.sh" <<'EOF'
#!/usr/bin/env bash
set_profile() {
  local PROFILE="$1"
  if ! command -v prime-select &>/dev/null; then return; fi
  
  case "$PROFILE" in
    integrated)
      prime-select intel 2>/dev/null || prime-select amd 2>/dev/null || true
      logger -t flytux "GPU: modo integrado"
      ;;
    performance)
      prime-select nvidia 2>/dev/null || true
      logger -t flytux "GPU: modo rendimiento"
      ;;
    on-demand)
      prime-select on-demand 2>/dev/null || true
      logger -t flytux "GPU: modo on-demand"
      ;;
  esac
}
case "$1" in
  set-profile) set_profile "$2" ;;
  query) prime-select query 2>/dev/null || echo "unknown" ;;
esac
EOF
chmod +x "$FLYTUX_LIB/modules/gpu.sh"

# Módulo Thermal MEJORADO: lee TJmax de hwmon, no de heurística
cat > "$FLYTUX