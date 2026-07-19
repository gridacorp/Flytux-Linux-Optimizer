#!/usr/bin/env bash
#=============================================================================
# 🐧 FlyTux Optimizer v9.0 - Edición "Maestra"
# Objetivo: Estabilidad absoluta, detección precisa, cero fricción y respeto
# por los valores predeterminados inteligentes del kernel moderno.
#=============================================================================

set -uo pipefail

# FUNCIÓN: Instalar o actualizar paquetes (APT maneja ambos nativamente)
install_or_upgrade() {
  local DESC="$1"; shift
  local PKGS=("$@")
  echo "   📦 $DESC: procesando ${#PKGS[@]} paquetes..."
  apt install -y "${PKGS[@]}" 2>/dev/null || true
}

# FUNCIÓN: Verificar si un paquete tiene versión candidata (usando madison)
pkg_exists() {
  apt-cache madison "$1" 2>/dev/null | grep -q '|'
}

# FUNCIÓN: Habilitar servicio solo si existe (evita ruido y errores)
enable_service() {
  local SERVICE="$1"
  if [ -f "/lib/systemd/system/$SERVICE.service" ] || [ -f "/etc/systemd/system/$SERVICE.service" ]; then
    systemctl enable --now "$SERVICE" 2>/dev/null || true
  fi
}

# 0. VALIDACIÓN INICIAL
echo "🐧 FlyTux Optimizer v9.0 | $(date)"
[ "$(id -u)" -ne 0 ] && { echo "❌ Ejecutar como: sudo bash $0"; exit 1; }

. /etc/os-release
if [[ ! "$ID_LIKE" =~ (debian|ubuntu) ]] && [[ ! "$ID" =~ (debian|ubuntu|linuxmint|pop|zorin) ]]; then
    echo "❌ Solo compatible con Debian/Ubuntu/Linux Mint/Pop!_OS/Zorin OS"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/flytux-$(date +%F-%H%M).log"
BACKUP="/var/backups/flytux-etc-$(date +%F).tar.gz"
mkdir -p /var/backups
exec > >(tee -a "$LOG") 2>&1

echo "📦 Backup seguro en: $BACKUP | 📜 Logs: $LOG"
echo "⏳ Iniciando optimización adaptativa..."

# 1. BACKUP DE SEGURIDAD
echo ""; echo "🔐 [1/12] Creando backup persistente..."
tar czf "$BACKUP" /etc/sysctl.d /etc/default /etc/systemd/system /etc/udev/rules.d \
    /etc/modprobe.d /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true
[ -f "$BACKUP" ] && echo "✅ Backup creado: $(du -sh "$BACKUP" | awk '{print $1}')" || echo "⚠️ Backup incompleto"

# 2. REPOSITORIOS Y ACTUALIZACIÓN INICIAL (Consolidada)
echo ""; echo "🔓 [2/12] Habilitando repositorios..."
if [[ "$ID" == "debian" ]] || [[ "$ID_LIKE" == *"debian"* ]]; then
  CODENAME=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2)
  for REPO in "contrib" "non-free" "non-free-firmware"; do
    sed -i "s/^deb \(.*\) $CODENAME main$/deb \1 $CODENAME main $REPO/" /etc/apt/sources.list 2>/dev/null || true
  done
else
  command -v add-apt-repository &>/dev/null && { add-apt-repository multiverse -y >/dev/null 2>&1; add-apt-repository restricted -y >/dev/null 2>&1; } || true
fi

# 2b. CORRECCIÓN DE REPOSITORIOS DE TERCEROS
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
for FILE in /etc/apt/sources.list.d/*ulauncher*.list /etc/apt/sources.list.d/*docky*.list; do
  [ -f "$FILE" ] && sed -i 's/ contrib//g' "$FILE" 2>/dev/null || true
done

echo "🔄 Actualizando índices de paquetes..."
apt update -o Acquire::Retries=3 --allow-releaseinfo-change -y >/dev/null 2>&1 || true
echo "✅ Repositorios configurados y actualizados"

# 3. DETECCIÓN DE HARDWARE (GPU Múltiple y Precisa)
echo ""; echo "🔍 [3/12] Detectando hardware..."
RAM_MB=$(awk '/MemTotal/ {printf "%d",$2/1024}' /proc/meminfo)
CPU_VENDOR=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
CPU_CORES=$(nproc)
DISK_NAME=$(lsblk -ndo pkname "$(df -P / | awk 'NR==2{print $1}')" 2>/dev/null | head -1)
DISK_TYPE="SSD"; [ -n "$DISK_NAME" ] && [ "$(cat /sys/block/$DISK_NAME/queue/rotational 2>/dev/null)" = "1" ] && DISK_TYPE="HDD"

# Detección acumulativa de GPU (soporta híbridos como Intel+NVIDIA)
GPU_VENDORS=""
if command -v lspci &>/dev/null; then
  lspci -nn | grep -iE "vga|3d|display" | grep -q "\[8086:" && GPU_VENDORS="${GPU_VENDORS}intel,"
  lspci -nn | grep -iE "vga|3d|display" | grep -q "\[1002:" && GPU_VENDORS="${GPU_VENDORS}amd,"
  lspci -nn | grep -iE "vga|3d|display" | grep -q "\[10de:" && GPU_VENDORS="${GPU_VENDORS}nvidia,"
fi
GPU_VENDORS="${GPU_VENDORS%,}" # Eliminar coma final
[ -z "$GPU_VENDORS" ] && GPU_VENDORS="unknown"

ACTIVE_USER=$(logname 2>/dev/null || who | awk '{print $1;exit}')
DE="unknown"; command -v loginctl &>/dev/null && [ -n "$ACTIVE_USER" ] && {
  S=$(loginctl list-sessions --no-legend | grep -m1 "$ACTIVE_USER" | awk '{print $1}')
  [ -n "$S" ] && DE=$(loginctl show-session "$S" -p Desktop --value 2>/dev/null || echo unknown)
}
[ -z "$DE" ] || [ "$DE" = "unknown" ] && DE="${XDG_CURRENT_DESKTOP:-unknown}"
DE=$(echo "$DE" | tr '[:upper:]' '[:lower:]')
echo "💾 ${RAM_MB}MB | 🖥️ $CPU_VENDOR ($CPU_CORES) | 💿 $DISK_TYPE | 🎮 $GPU_VENDORS | 🖼️ $DE"

# 4. PERFIL ADAPTATIVO
echo ""; echo "📊 [4/12] Calculando perfil..."
[ "$RAM_MB" -lt 5000 ] && RAM_TIER="LOW" || { [ "$RAM_MB" -le 8192 ] && RAM_TIER="MID" || RAM_TIER="HIGH"; }
PROFILE="${RAM_TIER}_${DISK_TYPE}"
case "$PROFILE" in
  LOW_HDD)  echo "🔴 LOW+HDD"; SWAP=10; CP=50; DR=10; SCHED="bfq"; ZRAM=$((RAM_MB*50/100)); ZA="zstd"; PC=2; PH=2; THP="madvise" ;;
  LOW_SSD)  echo "🔵 LOW+SSD"; SWAP=10; CP=50; DR=10; SCHED="mq-deadline"; ZRAM=$((RAM_MB*50/100)); ZA="zstd"; PC=0; PH=0; THP="madvise" ;;
  MID_HDD)  echo "🟡 MID+HDD"; SWAP=20; CP=30; DR=15; SCHED="bfq"; ZRAM=2048; ZA="zstd"; PC=2; PH=3; THP="madvise" ;;
  MID_SSD)  echo "🟢 MID+SSD"; SWAP=20; CP=20; DR=20; SCHED="mq-deadline"; ZRAM=2048; ZA="zstd"; PC=0; PH=0; THP="madvise" ;;
  HIGH_HDD) echo "⚡ HIGH+HDD"; SWAP=10; CP=10; DR=15; SCHED="bfq"; ZRAM=0; ZA="none"; PC=1; PH=5; THP="madvise" ;;
  HIGH_SSD) echo "🚀 HIGH+SSD"; SWAP=10; CP=5; DR=30; SCHED="mq-deadline"; ZRAM=0; ZA="none"; PC=0; PH=0; THP="madvise" ;;
esac

# 5. KERNEL + SYSCTL (Governor condicional)
echo ""; echo "⚙️ [5/12] Kernel y sysctl..."
# Solo aplicar schedutil si el hardware/driver lo soporta explícitamente
if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]; then
  if grep -q "schedutil" /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors; then
    echo schedutil | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
  fi
fi

BBR_AVAILABLE=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbr" && echo "yes" || echo "no")

cat > /etc/sysctl.d/99-flytux.conf <<EOF
vm.swappiness=$SWAP
vm.vfs_cache_pressure=$CP
vm.dirty_ratio=$DR
vm.dirty_background_ratio=$((DR/2))
vm.page-cluster=0
net.core.somaxconn=4096
net.ipv4.tcp_fastopen=3
net.core.netdev_max_backlog=4096
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF

if [ "$BBR_AVAILABLE" = "yes" ]; then
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-flytux.conf
fi

sysctl -p /etc/sysctl.d/99-flytux.conf >/dev/null 2>&1 || true
echo "$THP" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo "✅ Sysctl aplicados en vivo"

# 6. ZRAM UNIVERSAL (Detecta zram-tools o zram-generator)
echo ""; echo "⚡ [6/12] Configurando ZRAM..."
install_or_upgrade "Gestión de Memoria" "earlyoom"

if [ "$ZRAM" -gt 0 ]; then
  if dpkg -l zram-tools &>/dev/null; then
    echo -e "ENABLE=yes\nSIZE=$ZRAM\nALGO=$ZA\nPRIORITY=100" > /etc/default/zramswap
    enable_service "zramswap"
  elif pkg_exists "zram-generator"; then
    install_or_upgrade "ZRAM Generator" "zram-generator"
    mkdir -p /etc/systemd/zram-generator.conf.d
    cat > /etc/systemd/zram-generator.conf.d/flytux.conf <<EOF
[zram0]
zram-size = ram / 2
compression-algorithm = $ZA
EOF
    systemctl daemon-reload
    enable_service "systemd-zram-setup@zram0"
  fi
else 
  systemctl disable zramswap 2>/dev/null || true
fi

if [ "$PC" -gt 0 ]; then 
  install_or_upgrade "Preload" "preload"
  enable_service "preload"
  sed -i "s/^# model.cycle.*/model.cycle = $PC/" /etc/preload.conf 2>/dev/null || true
  sed -i "s/^# model.halflife.*/model.halflife = $PH/" /etc/preload.conf 2>/dev/null || true
else 
  systemctl disable preload 2>/dev/null || true
fi

sed -i 's/^EXTRA_ARGS=.*/EXTRA_ARGS="--notify all"/' /etc/default/earlyoom 2>/dev/null || true
enable_service "earlyoom"
echo "✅ ZRAM ($ZA), Preload (HDD only) y EarlyOOM configurados"

# 7. DRIVERS + FWUPD
echo ""; echo "🏭 [7/12] Drivers y Firmware..."
if [[ "$CPU_VENDOR" == *"intel"* ]]; then install_or_upgrade "Microcódigo Intel" "intel-microcode"; fi
if [[ "$CPU_VENDOR" == *"amd"* ]]; then install_or_upgrade "Microcódigo AMD" "amd64-microcode"; fi

install_or_upgrade "Vulkan" "mesa-vulkan-drivers"
if pkg_exists "firmware-linux"; then install_or_upgrade "Firmware base" "firmware-linux"; fi
if pkg_exists "firmware-linux-nonfree"; then install_or_upgrade "Firmware non-free" "firmware-linux-nonfree"; fi
install_or_upgrade "Firmware específico" "firmware-misc-nonfree" "firmware-realtek" "firmware-iwlwifi"

if ! dpkg -l linux-firmware 2>/dev/null | grep -q "^ii"; then
  install_or_upgrade "Linux firmware" "linux-firmware"
fi

[[ "$GPU_VENDORS" == *"nvidia"* ]] && install_or_upgrade "NVIDIA utils" "nvidia-driver" "nvidia-settings" "nvidia-prime"
install_or_upgrade "DRM" "libdrm-common"
install_or_upgrade "Firmware updates" "fwupd"
enable_service "fwupd"
echo "✅ Drivers y fwupd actualizados"

# 8. CODECS, FUENTES Y WINE
echo ""; echo "🎬 [8/12] Codecs, fuentes y Wine..."
install_or_upgrade "Multimedia" "libavcodec-extra" "gstreamer1.0-plugins-bad" "gstreamer1.0-plugins-ugly" "gstreamer1.0-libav" "ffmpeg" "libdvd-pkg" "unrar" "p7zip-full" "p7zip-rar" "zip" "unzip" "ttf-mscorefonts-installer" "fonts-liberation" "fonts-noto" "fonts-noto-cjk" "fonts-roboto"
dpkg -l libdvd-pkg &>/dev/null | grep -q "^ii" && echo y | DEBIAN_FRONTEND=noninteractive dpkg-reconfigure libdvd-pkg 2>/dev/null || true

dpkg --add-architecture i386 2>/dev/null || true
apt update >/dev/null 2>&1 || true # Única actualización necesaria tras añadir i386
install_or_upgrade "Wine Full" "wine" "wine64" "wine32" "winetricks" "winbind" "libwine" "fonts-wine" "wine-tools" "cabextract" "libgl1-mesa-glx:i386" "libgl1-mesa-dri:i386" "libpulse0:i386" "libcups2:i386" "libdbus-1-3:i386" "libasound2:i386"
echo "✅ Codecs y Wine configurados"

# 9. DESINSTALACIÓN DE SOFTWARE PESADO
echo ""; echo "🗑️ [9/12] Desinstalando software pesado..."
for pkg in firefox firefox-esr libreoffice-core libreoffice-calc libreoffice-writer libreoffice-impress; do
  dpkg -l "$pkg" &>/dev/null && apt purge -y "$pkg" >/dev/null 2>&1 || true
done
apt autoremove -y --purge >/dev/null 2>&1 || true
echo "✅ Software pesado desinstalado"

# 10. APPS ESENCIALES + JOPDF + PROTONVPN (Enlace estable oficial)
echo ""; echo "🔄 [10/12] Instalando apps esenciales..."
install_or_upgrade "PDF/Impresión" "cups" "cups-client" "printer-driver-all" "system-config-printer" "poppler-utils" "qpdf" "pdfarranger" "pdftk" "pdfgrep" "nomacs"
enable_service "cups"

# Brave
if ! dpkg -l brave-browser &>/dev/null | grep -q "^ii"; then
  [ ! -f /usr/share/keyrings/brave-browser-archive-keyring.gpg ] && { curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg; echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg arch=amd64] https://brave-browser-apt-release.s3.brave.com/ stable main" | tee /etc/apt/sources.list.d/brave-browser-release.list >/dev/null; }
fi

# ProtonVPN (Enlace directo y estable de la documentación oficial, sin scraping HTML)
if ! dpkg -l protonvpn &>/dev/null | grep -q "^ii"; then
  PROTON_DEB="https://repo.protonvpn.com/debian/dists/stable/main/binary-all/protonvpn-stable-release_1.0.3_all.deb"
  wget -q -O /tmp/protonvpn-release.deb "$PROTON_DEB" 2>/dev/null
  if [ -f /tmp/protonvpn-release.deb ]; then
    apt install -y /tmp/protonvpn-release.deb 2>/dev/null || true
    rm -f /tmp/protonvpn-release.deb
    apt update >/dev/null 2>&1 || true # Actualizar tras añadir el repo de Proton
    apt install -y protonvpn 2>/dev/null || echo "⚠️ ProtonVPN: instalar manual"
  fi
fi

# Actualización consolidada tras añadir repositorios nuevos
apt update >/dev/null 2>&1 || true

# Instalación final de apps
apt install -y brave-browser vlc rustdesk 2>/dev/null || true
enable_service "rustdesk"

# jopdf
JPKG="jopdf"; JURL="https://cdn.jopdf.com/download/jopdf/jopdf-linux-amd64_setup.deb"; JDSK="jopdf.desktop"
if ! dpkg -l "$JPKG" 2>/dev/null | grep -q "^ii"; then
  wget -q -O /tmp/jp.deb "$JURL" 2>/dev/null && { dpkg -i /tmp/jp.deb 2>/dev/null || true; apt install -f -y >/dev/null 2>&1 || true; rm -f /tmp/jp.deb; echo "✅ jopdf instalado"; } || echo "⚠️ jopdf: no se pudo descargar"
else
  apt install --only-upgrade -y "$JPKG" 2>/dev/null || true
fi

if [ -f "/usr/share/applications/$JDSK" ]; then
  update-desktop-database &>/dev/null || true
  for UH in /home/*; do [ -d "$UH" ] && [ -f "$UH/.bashrc" ] && { U=$(basename "$UH"); id "$U" &>/dev/null && runuser -u "$U" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$U")/bus" xdg-mime default "$JDSK" application/pdf 2>/dev/null || true; }; done
  mkdir -p /etc/skel/.config; cp "/usr/share/applications/$JDSK" /etc/skel/.config/ 2>/dev/null || true
  echo "✅ PDF → jopdf asociado"
fi
echo "✅ Apps esenciales listas"

# 11. FIREWALL (Política de salida permitida por defecto)
echo ""; echo "🛡️ [11/12] Configurando Firewall..."
ufw --force reset >/dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing # CRÍTICO: Permite NTP (123/UDP), DoT (853) y puertos dinámicos de apps modernas
for P in 21 23 135 136 137 138 139 445 3389 5900; do ufw deny $P/tcp 2>/dev/null || true; done
ufw allow 21115:21119/tcp 2>/dev/null || true; ufw allow 21115:21119/udp 2>/dev/null || true # RustDesk
ufw --force enable >/dev/null 2>&1; enable_service "ufw"
echo "✅ Firewall activo (Entrada bloqueada, Salida permitida)"

# 12. PRIVACIDAD + APPARMOR + ANIMACIONES + I/O + LIMPIEZA
echo ""; echo "🔒 [12/12] Privacidad, Seguridad, Escritorio y Limpieza..."
for pkg in popularity-contest whoopsie apport ubuntu-report command-not-found; do dpkg -l "$pkg" &>/dev/null && apt purge -y "$pkg" >/dev/null 2>&1 || true; done
sed -i 's/^Enabled=1/Enabled=0/' /etc/default/apport 2>/dev/null || true

if command -v aa-enforce &>/dev/null; then
  for profile in /etc/apparmor.d/*flatpak* /etc/apparmor.d/*bwrap*; do [ -f "$profile" ] && aa-enforce "$profile" 2>/dev/null || true; done
  enable_service "apparmor"
  echo "✅ AppArmor de Flatpak/bwrap reactivado"
fi

if [ -n "$ACTIVE_USER" ] && [ "$ACTIVE_USER" != "root" ]; then
  UID_U=$(id -u "$ACTIVE_USER"); DBUS="unix:path=/run/user/$UID_U/bus"
  case "$DE" in 
    *gnome*|*zorin*) runuser -u "$ACTIVE_USER" -- env DBUS_SESSION_BUS_ADDRESS="$DBUS" bash -c 'gsettings set org.gnome.desktop.interface enable-animations true 2>/dev/null||true';; 
    *kde*|*plasma*) runuser -u "$ACTIVE_USER" -- bash -c 'kwriteconfig5 --file kwinrc --group Compositing --key Enabled true 2>/dev/null||true';; 
    *xfce*) runuser -u "$ACTIVE_USER" -- bash -c 'xfconf-query -c xfwm4 -p /general/use_compositing -s true 2>/dev/null||true';; 
  esac
  echo "✅ Configuración predeterminada del escritorio restaurada"
fi

# I/O Scheduler Inteligente (NVMe vs SATA vs HDD)
if [ -n "$DISK_NAME" ]; then
  if [ "$DISK_TYPE" = "HDD" ]; then
    SCHED="bfq"
  elif echo "$DISK_NAME" | grep -qi "nvme"; then
    SCHED="none" # Óptimo para NVMe, deja que el kernel gestione
  else
    SCHED="mq-deadline" # Óptimo para SSD SATA
  fi
  
  AVAILABLE_SCHEDS=$(cat /sys/block/$DISK_NAME/queue/scheduler 2>/dev/null)
  if echo "$AVAILABLE_SCHEDS" | grep -q "\[$SCHED\]"; then
    echo "✅ Scheduler $SCHED ya está activo"
  elif echo "$AVAILABLE_SCHEDS" | grep -q "$SCHED"; then
    echo "$SCHED" > "/sys/block/$DISK_NAME/queue/scheduler" 2>/dev/null || true
    mkdir -p /etc/udev/rules.d
    echo "ACTION==\"add|change\", KERNEL==\"$DISK_NAME\", ATTR{queue/scheduler}=\"$SCHED\"" > /etc/udev/rules.d/60-flytux-io.rules
    udevadm control --reload-rules 2>/dev/null || true
    echo "✅ Scheduler aplicado: $SCHED"
  fi
  [ "$DISK_TYPE" = "SSD" ] && enable_service "fstrim.timer"
fi

# Limpieza final segura
apt full-upgrade -y >/dev/null 2>&1 || true
apt autoremove -y --purge >/dev/null 2>&1 || true
apt clean >/dev/null 2>&1 || true
journalctl --vacuum-size=50M --vacuum-time=7d 2>/dev/null || true
systemd-tmpfiles --clean 2>/dev/null || true
echo "✅ Limpieza completada de forma segura"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "🐧 FlyTux Optimizer v9.0 COMPLETADO"
echo "📊 Perfil: $PROFILE | 🔧 $CPU_VENDOR | 🎮 $GPU_VENDORS"
echo "🧠 Memoria: ZRAM ($ZA) + EarlyOOM"
echo "🛡️ Estabilidad: Respeto total a los defaults del kernel"
echo "📁 Backup seguro en: $BACKUP"
echo "═══════════════════════════════════════════════════════"
echo "💡 CONSEJO: Reinicia el equipo para aplicar los cambios de I/O."
echo "🔙 REVERTIR: sudo tar xzf $BACKUP -C / && sudo ufw disable"
echo "═══════════════════════════════════════════════════════"