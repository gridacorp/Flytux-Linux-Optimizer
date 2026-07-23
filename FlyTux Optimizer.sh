#!/usr/bin/env bash
#=============================================================================
# 🐧 FlyTux Optimizer v16.0 - Edición "Conciencia Persistente"
# Objetivo: Perfil persistente de hardware, gestión térmica adaptativa,
# configuración PRIME para sistemas híbridos, y limpieza inteligente de servicios.
#=============================================================================

set -Eeuo pipefail
trap 'echo "❌ Error en línea $LINENO: $BASH_COMMAND" >&2' ERR

# FUNCIÓN: Instalar o actualizar paquetes
install_or_upgrade() {
  local DESC="$1"; shift
  local PKGS=("$@")
  [ ${#PKGS[@]} -eq 0 ] && return
  echo "   📦 $DESC: procesando ${#PKGS[@]} paquetes..."
  apt install -y "${PKGS[@]}" 2>/dev/null || true
}

# FUNCIÓN: Verificar si un paquete tiene versión candidata instalable
pkg_exists() {
  apt-cache madison "$1" 2>/dev/null | grep -q '|'
}

# FUNCIÓN: Habilitar servicio SOLO si systemd lo reconoce
enable_service() {
  local SERVICE="$1"
  if systemctl list-unit-files "${SERVICE}.service" 2>/dev/null | grep -q "${SERVICE}.service"; then
    systemctl enable --now "$SERVICE" 2>/dev/null || true
  fi
}

# FUNCIÓN: Desactivar servicio de forma segura
disable_service() {
  local SERVICE="$1"
  if systemctl list-unit-files "${SERVICE}.service" 2>/dev/null | grep -q "${SERVICE}.service"; then
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    echo "   🔕 Servicio '$SERVICE' desactivado (no necesario en este hardware)."
  fi
}

# 0. VALIDACIÓN INICIAL
echo "🐧 FlyTux Optimizer v16.0 | $(date)"
[ "$(id -u)" -ne 0 ] && { echo "❌ Ejecutar como: sudo bash $0"; exit 1; }

. /etc/os-release
if [[ ! "$ID_LIKE" =~ (debian|ubuntu) ]] && [[ ! "$ID" =~ (debian|ubuntu|linuxmint|pop|zorin) ]]; then
    echo "❌ Solo compatible con Debian/Ubuntu/Linux Mint/Pop!_OS/Zorin OS"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/flytux-$(date +%F-%H%M).log"
BACKUP="/var/backups/flytux-etc-$(date +%F).tar.gz"
PROFILE_DIR="/etc/flytux"
PROFILE_FILE="$PROFILE_DIR/hardware-profile.json"
mkdir -p /var/backups "$PROFILE_DIR"
exec > >(tee -a "$LOG") 2>&1

echo "📦 Backup seguro en: $BACKUP | 📜 Logs: $LOG"
echo "⏳ Iniciando optimización con conciencia persistente..."

# 1. BACKUP DE SEGURIDAD
echo ""; echo "🔐 [1/13] Creando backup persistente..."
tar czf "$BACKUP" /etc/sysctl.d /etc/default /etc/systemd/system /etc/udev/rules.d \
    /etc/modprobe.d /etc/apt/sources.list /etc/apt/sources.list.d/ /etc/apt/sources.sources 2>/dev/null || true
[ -f "$BACKUP" ] && echo "✅ Backup creado: $(du -sh "$BACKUP" | awk '{print $1}')" || echo "⚠️ Backup incompleto"

# 2. REPOSITORIOS
echo ""; echo "🔓 [2/13] Habilitando repositorios..."
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

fix_repo_arch() {
  for FILE in $1; do
    [ -f "$FILE" ] || continue
    if [[ "$FILE" == *.sources ]]; then
      grep -q "^Architectures:" "$FILE" 2>/dev/null || echo "Architectures: amd64" >> "$FILE"
      sed -i '/^Components:/s/ contrib//g' "$FILE" 2>/dev/null || true
    else
      sed -i -E 's/^deb (https?:\/\/[^ ]+)/deb [arch=amd64] \1/' "$FILE" 2>/dev/null || true
      sed -i 's/ contrib//g' "$FILE" 2>/dev/null || true
    fi
  done
}
fix_repo_arch "/etc/apt/sources.list.d/*brave*.list /etc/apt/sources.list.d/brave*.sources"
fix_repo_arch "/etc/apt/sources.list.d/*chrome*.list /etc/apt/sources.list.d/google*.sources"
fix_repo_arch "/etc/apt/sources.list.d/*protonvpn*.list"

apt update -o Acquire::Retries=3 --allow-releaseinfo-change -y >/dev/null 2>&1 || true
echo "✅ Repositorios configurados y actualizados"

# 3. DIAGNÓSTICO AVANZADO DE HARDWARE
echo ""; echo "🔍 [3/13] Diagnóstico avanzado de hardware..."
RAM_MB=$(awk '/MemTotal/ {printf "%d",$2/1024}' /proc/meminfo)
SWAP_TOTAL=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
HAS_SWAP=$([ "$SWAP_TOTAL" -gt 0 ] && echo "yes" || echo "no")

IS_LAPTOP="no"
ls /sys/class/power_supply/BAT* >/dev/null 2>&1 && IS_LAPTOP="yes"

BOOT_MODE="BIOS"
[ -d /sys/firmware/efi ] && BOOT_MODE="UEFI"

SECURE_BOOT="unknown"
if command -v mokutil &>/dev/null; then
  mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled" && SECURE_BOOT="enabled"
  mokutil --sb-state 2>/dev/null | grep -q "SecureBoot disabled" && SECURE_BOOT="disabled"
fi

CPU_VENDOR=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
CPU_CORES=$(nproc)
CPU_FAMILY=$(grep -m1 "cpu family" /proc/cpuinfo | awk '{print $4}')
CPU_MODEL_NUM=$(grep -m1 "^model[[:space:]]*:" /proc/cpuinfo | awk '{print $3}')
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)

CPU_FLAGS=$(grep -m1 "^flags" /proc/cpuinfo | tr '[:upper:]' '[:lower:]')
HAS_AES=$(echo "$CPU_FLAGS" | grep -qw "aes" && echo "yes" || echo "no")
HAS_AVX2=$(echo "$CPU_FLAGS" | grep -qw "avx2" && echo "yes" || echo "no")
HAS_AVX512=$(echo "$CPU_FLAGS" | grep -qw "avx512f" && echo "yes" || echo "no")

IS_HYBRID_CPU="no"
if [ -d /sys/devices/system/cpu ]; then
  CAPACITIES=$(cat /sys/devices/system/cpu/cpu*/cpu_capacity 2>/dev/null | sort -u | wc -l)
  [ "$CAPACITIES" -gt 1 ] && IS_HYBRID_CPU="yes"
fi
if [ "$IS_HYBRID_CPU" = "no" ] && [[ "$CPU_VENDOR" == *"intel"* ]] && [ "$CPU_FAMILY" = "6" ]; then
  case "$CPU_MODEL_NUM" in
    151|154|155|158|165|170|173|185|198) IS_HYBRID_CPU="yes" ;;
  esac
fi

CPU_GEN="unknown"
if [[ "$CPU_VENDOR" == *"intel"* ]] && [ "$CPU_FAMILY" = "6" ]; then
  case "$CPU_MODEL_NUM" in
    151|154|155) CPU_GEN="Alder Lake (12th)" ;;
    158|165) CPU_GEN="Raptor Lake (13th)" ;;
    170) CPU_GEN="Raptor Lake Refresh (14th)" ;;
    173) CPU_GEN="Meteor Lake (Core Ultra 1)" ;;
    185) CPU_GEN="Lunar Lake (Core Ultra 2)" ;;
    198) CPU_GEN="Arrow Lake (Core Ultra 3)" ;;
    140|141) CPU_GEN="Tiger Lake (11th)" ;;
    126|142) CPU_GEN="Ice/Comet Lake (10th)" ;;
  esac
elif [[ "$CPU_VENDOR" == *"amd"* ]]; then
  if [ "$CPU_FAMILY" = "26" ]; then CPU_GEN="Zen 5"
  elif [ "$CPU_FAMILY" = "25" ]; then
    [ "$CPU_MODEL_NUM" -ge 16 ] 2>/dev/null && CPU_GEN="Zen 4" || CPU_GEN="Zen 3"
  elif [ "$CPU_FAMILY" = "23" ]; then
    [ "$CPU_MODEL_NUM" -ge 112 ] 2>/dev/null && CPU_GEN="Zen 2" || CPU_GEN="Zen / Zen+"
  fi
fi

DISK_NAME=$(lsblk -ndo pkname "$(df -P / | awk 'NR==2{print $1}')" 2>/dev/null | head -1)
DISK_TYPE="HDD"
if [ -n "$DISK_NAME" ]; then
  [ "$(cat /sys/block/$DISK_NAME/queue/rotational 2>/dev/null)" = "0" ] && DISK_TYPE="SSD_SATA"
  echo "$DISK_NAME" | grep -qi "nvme" && DISK_TYPE="NVME"
fi

# Lista de todos los discos para el perfil
ALL_DISKS=$(lsblk -dnro NAME,TYPE,SIZE,MODEL 2>/dev/null | awk '$2=="disk"{printf "%s(%s),", $1, $3}' | sed 's/,$//')

SUPPORTS_TRIM="no"
if [ "$DISK_TYPE" != "HDD" ] && [ -n "$DISK_NAME" ]; then
  DISC_INFO=$(lsblk --discard "/dev/$DISK_NAME" 2>/dev/null | tail -n 1)
  if echo "$DISC_INFO" | grep -qE "yes|1"; then
    SUPPORTS_TRIM="yes"
  fi
fi

HAS_ECC="no"
if [ -d /sys/devices/system/edac/mc ]; then
  if ls /sys/devices/system/edac/mc/mc*/ce_count 2>/dev/null | head -1 | grep -q "ce_count"; then
    HAS_ECC="yes"
  fi
fi
if [ "$HAS_ECC" = "no" ] && command -v dmidecode &>/dev/null; then
  if dmidecode -t memory 2>/dev/null | grep -q "ECC"; then
    HAS_ECC="yes"
  fi
fi

# GPU
GPU_VENDORS=""
PRIMARY_GPU_DRIVER="unknown"
HAS_HYBRID_GPU="no"

if command -v lspci &>/dev/null; then
  GPU_COUNT=0
  lspci -nn | grep -iE "vga|3d|display" | grep -q "\[8086:" && { GPU_VENDORS="${GPU_VENDORS}intel,"; GPU_COUNT=$((GPU_COUNT+1)); }
  lspci -nn | grep -iE "vga|3d|display" | grep -q "\[1002:" && { GPU_VENDORS="${GPU_VENDORS}amd,"; GPU_COUNT=$((GPU_COUNT+1)); }
  lspci -nn | grep -iE "vga|3d|display" | grep -q "\[10de:" && { GPU_VENDORS="${GPU_VENDORS}nvidia,"; GPU_COUNT=$((GPU_COUNT+1)); }
  [ "$GPU_COUNT" -gt 1 ] && HAS_HYBRID_GPU="yes"
  
  if command -v glxinfo &>/dev/null; then
    RENDERER=$(glxinfo 2>/dev/null | grep "OpenGL renderer string" | tr '[:upper:]' '[:lower:]')
    if echo "$RENDERER" | grep -q "intel"; then PRIMARY_GPU_DRIVER="i915"
    elif echo "$RENDERER" | grep -qE "amd|radeon"; then PRIMARY_GPU_DRIVER="amdgpu"
    elif echo "$RENDERER" | grep -q "nvidia"; then PRIMARY_GPU_DRIVER="nvidia"
    fi
  fi
  
  if [ "$PRIMARY_GPU_DRIVER" = "unknown" ] && command -v vulkaninfo &>/dev/null; then
    DEVICE=$(vulkaninfo 2>/dev/null | grep "deviceName" | head -n 1 | tr '[:upper:]' '[:lower:]')
    if echo "$DEVICE" | grep -q "intel"; then PRIMARY_GPU_DRIVER="i915"
    elif echo "$DEVICE" | grep -qE "amd|radeon"; then PRIMARY_GPU_DRIVER="amdgpu"
    elif echo "$DEVICE" | grep -q "nvidia"; then PRIMARY_GPU_DRIVER="nvidia"
    fi
  fi
  
  if [ "$PRIMARY_GPU_DRIVER" = "unknown" ] && [ -d /sys/class/drm ]; then
    for CARD in /sys/class/drm/card*; do
      [ -d "$CARD" ] || continue
      if ls "$CARD"/card*-HDMI-* "$CARD"/card*-DP-* 2>/dev/null | xargs grep -l "connected" 2>/dev/null | head -1 | grep -q .; then
        DRIVER=$(readlink "$CARD/device/driver" 2>/dev/null | xargs basename)
        [ -n "$DRIVER" ] && PRIMARY_GPU_DRIVER="$DRIVER" && break
      fi
    done
  fi
  
  if [ "$PRIMARY_GPU_DRIVER" = "unknown" ]; then
    PRIMARY_GPU_DRIVER=$(lspci -nnk | grep -i "vga compatible controller" -A 2 | grep "Kernel driver in use:" | awk '{print $4}' | tr '[:upper:]' '[:lower:]' | head -n 1)
  fi
fi
GPU_VENDORS="${GPU_VENDORS%,}"
[ -z "$GPU_VENDORS" ] && GPU_VENDORS="unknown"

# Pantalla (resolución y conectores)
DISPLAY_INFO="unknown"
if command -v xrandr &>/dev/null && [ -n "$ACTIVE_USER" ]; then
  DISPLAY_INFO=$(runuser -u "$ACTIVE_USER" -- xrandr 2>/dev/null | grep " connected" | awk '{print $1, $3}' | head -n 1 | xargs)
  [ -z "$DISPLAY_INFO" ] && DISPLAY_INFO="unknown"
fi

# Sensores térmicos
HAS_SENSORS="no"
command -v sensors &>/dev/null && sensors 2>/dev/null | grep -q "Core\|Tctl\|Package" && HAS_SENSORS="yes"

# Bluetooth
HAS_BLUETOOTH="no"
command -v hciconfig &>/dev/null && hciconfig 2>/dev/null | grep -q "hci" && HAS_BLUETOOTH="yes"
[ "$HAS_BLUETOOTH" = "no" ] && lspci -nn 2>/dev/null | grep -qi "bluetooth" && HAS_BLUETOOTH="yes"
[ "$HAS_BLUETOOTH" = "no" ] && lsusb 2>/dev/null | grep -qi "bluetooth" && HAS_BLUETOOTH="yes"

# Modem (3G/4G/5G)
HAS_MODEM="no"
command -v mmcli &>/dev/null && mmcli -L 2>/dev/null | grep -q "modem" && HAS_MODEM="yes"
[ "$HAS_MODEM" = "no" ] && lsusb 2>/dev/null | grep -qiE "modem|lte|4g|5g" && HAS_MODEM="yes"

ACTIVE_USER=$(logname 2>/dev/null || who | awk '{print $1;exit}')
DE="unknown"; command -v loginctl &>/dev/null && [ -n "$ACTIVE_USER" ] && {
  S=$(loginctl list-sessions --no-legend | grep -m1 "$ACTIVE_USER" | awk '{print $1}')
  [ -n "$S" ] && DE=$(loginctl show-session "$S" -p Desktop --value 2>/dev/null || echo unknown)
}
[ -z "$DE" ] || [ "$DE" = "unknown" ] && DE="${XDG_CURRENT_DESKTOP:-unknown}"
DE=$(echo "$DE" | tr '[:upper:]' '[:lower:]')

echo "💾 ${RAM_MB}MB RAM | 🔄 Swap: $HAS_SWAP | 💻 Laptop: $IS_LAPTOP | ECC: $HAS_ECC"
echo "🖥️ CPU: $CPU_VENDOR $CPU_GEN | Híbrida: $IS_HYBRID_CPU | AVX512: $HAS_AVX512"
echo "💿 Disco: $DISK_TYPE | TRIM: $SUPPORTS_TRIM"
echo "🎮 GPU: $GPU_VENDORS (Primaria: $PRIMARY_GPU_DRIVER) | Híbrida GPU: $HAS_HYBRID_GPU"
echo "🖥️ Pantalla: $DISPLAY_INFO | 🌡️ Sensores: $HAS_SENSORS | 📶 BT: $HAS_BLUETOOTH | 📡 Modem: $HAS_MODEM"
echo "🔐 Boot: $BOOT_MODE | Secure Boot: $SECURE_BOOT | 🖼️ $DE"

# 4. GENERACIÓN DE PERFIL PERSISTENTE
echo ""; echo "💾 [4/13] Generando perfil persistente de hardware..."
cat > "$PROFILE_FILE" <<EOF
{
  "version": "16.0",
  "generated": "$(date -Iseconds)",
  "distro": "$ID $VERSION_ID",
  "hardware": {
    "cpu": {
      "vendor": "$CPU_VENDOR",
      "model": "$CPU_MODEL",
      "generation": "$CPU_GEN",
      "family": "$CPU_FAMILY",
      "model_num": "$CPU_MODEL_NUM",
      "cores": $CPU_CORES,
      "hybrid": $IS_HYBRID_CPU,
      "aes": $HAS_AES,
      "avx2": $HAS_AVX2,
      "avx512": $HAS_AVX512
    },
    "ram": {
      "total_mb": $RAM_MB,
      "ecc": $HAS_ECC,
      "swap_total_kb": $SWAP_TOTAL
    },
    "disks": {
      "primary": "$DISK_NAME",
      "primary_type": "$DISK_TYPE",
      "supports_trim": $SUPPORTS_TRIM,
      "all": "$ALL_DISKS"
    },
    "gpu": {
      "vendors": "$GPU_VENDORS",
      "primary_driver": "$PRIMARY_GPU_DRIVER",
      "hybrid": $HAS_HYBRID_GPU
    },
    "display": "$DISPLAY_INFO",
    "form_factor": "$([ "$IS_LAPTOP" = "yes" ] && echo "laptop" || echo "desktop")",
    "has_bluetooth": $HAS_BLUETOOTH,
    "has_modem": $HAS_MODEM,
    "has_thermal_sensors": $HAS_SENSORS,
    "boot_mode": "$BOOT_MODE",
    "secure_boot": "$SECURE_BOOT"
  },
  "desktop": {
    "environment": "$DE",
    "active_user": "$ACTIVE_USER"
  }
}
EOF
chmod 644 "$PROFILE_FILE"
echo "✅ Perfil guardado en: $PROFILE_FILE"

# 5. MOTOR DE PERFILES ADAPTATIVOS
echo ""; echo "📊 [5/13] Calculando perfil de optimización..."
if [ "$RAM_MB" -le 4096 ]; then RAM_TIER="LOW (≤4GB)"
elif [ "$RAM_MB" -le 8192 ]; then RAM_TIER="MID (≤8GB)"
elif [ "$RAM_MB" -le 16384 ]; then RAM_TIER="HIGH (≤16GB)"
else RAM_TIER="ULTRA (>16GB)"; fi

USE_ZRAM="no"; USE_PRELOAD="no"; USE_EARLYOOM="no"

if [[ "$RAM_TIER" == "LOW"* ]]; then
  USE_ZRAM="yes"; USE_EARLYOOM="yes"
  [ "$DISK_TYPE" == "HDD" ] && USE_PRELOAD="yes"
elif [[ "$RAM_TIER" == "MID"* ]]; then
  USE_ZRAM="yes"
  [ "$DISK_TYPE" == "HDD" ] && { USE_EARLYOOM="yes"; USE_PRELOAD="yes"; }
  [ "$HAS_SWAP" == "no" ] && USE_EARLYOOM="yes"
elif [[ "$RAM_TIER" == "HIGH"* ]]; then
  [ "$HAS_SWAP" == "no" ] && USE_EARLYOOM="yes"
fi

ZRAM_SIZE=$((RAM_MB * 50 / 100))
[ "$ZRAM_SIZE" -gt 4096 ] && ZRAM_SIZE=4096

echo "✅ Perfil: $RAM_TIER + $DISK_TYPE | ZRAM: $USE_ZRAM | EarlyOOM: $USE_EARLYOOM | Preload: $USE_PRELOAD"

# 6. KERNEL + SYSCTL
echo ""; echo "⚙️ [6/13] Ajustes de kernel..."
if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]; then
  if grep -q "schedutil" /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors; then
    echo schedutil | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
  fi
fi

cat > /etc/sysctl.d/99-flytux.conf <<EOF
net.core.somaxconn=4096
net.ipv4.tcp_fastopen=3
net.core.netdev_max_backlog=4096
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbr"; then
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-flytux.conf
fi
sysctl -p /etc/sysctl.d/99-flytux.conf >/dev/null 2>&1 || true
echo "✅ Sysctl de red aplicados."

# 7. APLICACIÓN DEL MOTOR DE PERFILES
echo ""; echo "⚡ [7/13] Aplicando optimizaciones de perfil..."

if [ "$USE_ZRAM" == "yes" ]; then
  if [ -b /dev/zram0 ] || [ -d /sys/block/zram0 ]; then
    echo "ℹ️ ZRAM ya activo."
  elif pkg_exists "systemd-zram-generator"; then
    install_or_upgrade "ZRAM Generator" "systemd-zram-generator"
    mkdir -p /etc/systemd/zram-generator.conf.d
    echo -e "[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf.d/flytux.conf
    systemctl daemon-reload
    enable_service "systemd-zram-setup@zram0"
  elif pkg_exists "zram-tools"; then
    install_or_upgrade "ZRAM Tools" "zram-tools"
    echo -e "ENABLE=yes\nSIZE=$ZRAM_SIZE\nALGO=zstd\nPRIORITY=100" > /etc/default/zramswap
    enable_service "zramswap"
  fi
fi

if [ "$USE_EARLYOOM" == "yes" ]; then
  install_or_upgrade "EarlyOOM" "earlyoom"
  sed -i 's/^EXTRA_ARGS=.*/EXTRA_ARGS="--notify all"/' /etc/default/earlyoom 2>/dev/null || true
  enable_service "earlyoom"
fi

if [ "$USE_PRELOAD" == "yes" ] && [ "$DISK_TYPE" == "HDD" ]; then
  install_or_upgrade "Preload" "preload"
  enable_service "preload"
  sed -i "s/^# model.cycle.*/model.cycle = 2/" /etc/preload.conf 2>/dev/null || true
  sed -i "s/^# model.halflife.*/model.halflife = 2/" /etc/preload.conf 2>/dev/null || true
fi

echo "✅ Perfil de rendimiento aplicado."

# 8. GESTIÓN TÉRMICA ADAPTATIVA
echo ""; echo "🌡️ [8/13] Configurando gestión térmica..."

if [ "$IS_LAPTOP" == "yes" ]; then
  if [[ "$CPU_VENDOR" == *"intel"* ]]; then
    # Intel: thermald es el gestor térmico oficial de Intel
    install_or_upgrade "Thermal Daemon (Intel)" "thermald"
    enable_service "thermald"
    echo "✅ thermald activado (gestión térmica Intel adaptativa)."
  fi
  
  # power-profiles-daemon para todos los laptops modernos (Ubuntu/Mint/Pop/Zorin)
  if [[ "$ID" != "debian" ]] && [[ "$ID_LIKE" != *"debian"* ]]; then
    install_or_upgrade "Power Profiles Daemon" "power-profiles-daemon"
    enable_service "power-profiles-daemon"
    echo "✅ power-profiles-daemon activado (perfiles AC/Batería)."
  else
    # Debian: TLP como alternativa
    install_or_upgrade "TLP (Gestión de energía)" "tlp" "tlp-rdw"
    enable_service "tlp"
    echo "✅ TLP activado (gestión de energía adaptativa AC/Batería)."
  fi
else
  # Escritorio: solo asegurar que no haya conflictos
  systemctl disable --now thermald 2>/dev/null || true
  systemctl disable --now tlp 2>/dev/null || true
  echo "ℹ️ Modo escritorio: gestión térmica de portátil desactivada."
fi

# NOTA: tuned NO se instala porque es de Red Hat y causa conflictos con power-profiles-daemon

# 9. OPTIMIZACIÓN GRÁFICA (PRIME para híbridos)
echo ""; echo "🎮 [9/13] Optimización gráfica..."

# Paquetes VAAPI/Vulkan según GPU
if [[ "$GPU_VENDORS" == *"intel"* ]]; then
  VA_PKGS=()
  pkg_exists "intel-media-driver" && VA_PKGS+=("intel-media-driver")
  pkg_exists "intel-media-va-driver-non-free" && VA_PKGS+=("intel-media-va-driver-non-free")
  pkg_exists "intel-gpu-tools" && VA_PKGS+=("intel-gpu-tools")
  pkg_exists "mesa-va-drivers" && VA_PKGS+=("mesa-va-drivers")
  pkg_exists "mesa-vulkan-drivers" && VA_PKGS+=("mesa-vulkan-drivers")
  [ ${#VA_PKGS[@]} -gt 0 ] && install_or_upgrade "Intel VAAPI/Vulkan" "${VA_PKGS[@]}"
fi

if [[ "$GPU_VENDORS" == *"amd"* ]]; then
  AMD_PKGS=()
  pkg_exists "firmware-amd-graphics" && AMD_PKGS+=("firmware-amd-graphics")
  pkg_exists "mesa-vulkan-drivers" && AMD_PKGS+=("mesa-vulkan-drivers")
  pkg_exists "mesa-va-drivers" && AMD_PKGS+=("mesa-va-drivers")
  pkg_exists "mesa-vdpau-drivers" && AMD_PKGS+=("mesa-vdpau-drivers")
  pkg_exists "libdrm-amdgpu1" && AMD_PKGS+=("libdrm-amdgpu1")
  [ ${#AMD_PKGS[@]} -gt 0 ] && install_or_upgrade "AMD VAAPI/Vulkan" "${AMD_PKGS[@]}"
fi

if [[ "$GPU_VENDORS" == *"nvidia"* ]]; then
  NVIDIA_PKG="nvidia-driver"
  if command -v ubuntu-drivers &>/dev/null; then
    REC_DRIVER=$(ubuntu-drivers devices 2>/dev/null | grep "recommended" | awk '{print $3}')
    [ -n "$REC_DRIVER" ] && NVIDIA_PKG="$REC_DRIVER"
  fi
  
  if [ "$SECURE_BOOT" == "enabled" ]; then
    echo ""
    echo "⚠️ ════════════════════════════════════════════════════════"
    echo "⚠️  ADVERTENCIA: Secure Boot ACTIVADO"
    echo "⚠️  NVIDIA requiere firma MOK. Instalación omitida por seguridad."
    echo "⚠️  Manual: sudo apt install $NVIDIA_PKG && sudo mokutil --import /var/lib/dkms/mok.pub"
    echo "⚠️ ════════════════════════════════════════════════════════"
    read -r -p "¿Instalar NVIDIA de todos modos? [y/N] " response
    if 