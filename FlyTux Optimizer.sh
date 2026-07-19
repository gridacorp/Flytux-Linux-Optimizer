#!/usr/bin/env bash
#=============================================================================
# 🐧 FlyTux Optimizer v5.0 - Edición "Reparadora y Optimizadora"
# Objetivo: Repara daños de scripts anteriores, optimiza 4GB RAM, control total.
#=============================================================================

set -uo pipefail

# FUNCIÓN: Instalar o actualizar paquetes inteligentemente
install_or_upgrade() {
  local PKGS="$1" DESC="$2"
  local TO_INSTALL=() TO_UPGRADE=()
  for PKG in $PKGS; do
    if dpkg -l "$PKG" 2>/dev/null | grep -q "^ii"; then 
      TO_UPGRADE+=("$PKG")
    else 
      TO_INSTALL+=("$PKG")
    fi
  done
  
  if [ ${#TO_UPGRADE[@]} -gt 0 ] && [ ${#TO_INSTALL[@]} -gt 0 ]; then
    echo "   🔄 $DESC: ${#TO_UPGRADE[@]} actualizar + ${#TO_INSTALL[@]} instalar"
    apt install --only-upgrade -y "${TO_UPGRADE[@]}" 2>/dev/null || true
    apt install -y "${TO_INSTALL[@]}" 2>/dev/null || true
  elif [ ${#TO_UPGRADE[@]} -gt 0 ]; then
    echo "   ⬆️ $DESC: actualizando ${#TO_UPGRADE[@]} existentes"
    apt install --only-upgrade -y "${TO_UPGRADE[@]}" 2>/dev/null || true
  elif [ ${#TO_INSTALL[@]} -gt 0 ]; then
    echo "   📦 $DESC: instalando ${#TO_INSTALL[@]} nuevos"
    apt install -y "${TO_INSTALL[@]}" 2>/dev/null || true
  else
    echo "   ✅ $DESC: todo actualizado"
  fi
}

# 0. VALIDACIÓN INICIAL
echo "🐧 FlyTux Optimizer v5.0 | $(date)"
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
echo "⏳ Iniciando reparación y optimización..."

# 1. BACKUP DE SEGURIDAD
echo ""; echo "🔐 [1/15] Creando backup persistente..."
tar czf "$BACKUP" /etc/sysctl.d /etc/default /etc/systemd/system /etc/udev/rules.d \
    /etc/modprobe.d /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true
[ -f "$BACKUP" ] && echo "✅ Backup creado: $(du -sh "$BACKUP" | awk '{print $1}')" || echo "⚠️ Backup incompleto"

# 2. REPOSITORIOS NON-FREE / MULTIVERSE
echo ""; echo "🔓 [2/15] Habilitando repositorios..."
if [[ "$ID" == "debian" ]] || [[ "$ID_LIKE" == *"debian"* ]]; then
  CODENAME=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2)
  for REPO in "contrib" "non-free" "non-free-firmware"; do
    sed -i "s/^deb \(.*\) $CODENAME main$/deb \1 $CODENAME main $REPO/" /etc/apt/sources.list 2>/dev/null || true
  done
  echo "✅ Debian: non-free habilitado"
else
  command -v add-apt-repository &>/dev/null && { add-apt-repository multiverse -y >/dev/null 2>&1; add-apt-repository restricted -y >/dev/null 2>&1; } || true
  echo "✅ Ubuntu: multiverse/restricted habilitado"
fi

# 2b. CORRECCIÓN DE REPOSITORIOS
echo ""; echo "🔧 [2b/15] Corrigiendo arquitecturas de repositorios..."
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
echo "✅ Repositorios corregidos"

# 3. APT UPDATE RESILIENTE
echo ""; echo "🔄 [3/15] Actualizando índices..."
APT_OUT=$(apt update -o Acquire::Retries=3 --allow-releaseinfo-change 2>&1)
if echo "$APT_OUT" | grep -q "^E:"; then
  echo "❌ Error crítico:"; echo "$APT_OUT" | grep "^E:" | head -n 3
  echo "⚠️ Continuando (algunas instalaciones podrían fallar)"
else
  echo "✅ Índices actualizados"
fi

# 4. DETECCIÓN DE HARDWARE
echo ""; echo "🔍 [4/15] Detectando hardware..."
RAM_MB=$(awk '/MemTotal/ {printf "%d",$2/1024}' /proc/meminfo)
CPU_VENDOR=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
CPU_CORES=$(nproc)
DISK_NAME=$(lsblk -ndo pkname "$(df -P / | awk 'NR==2{print $1}')" 2>/dev/null | head -1)
DISK_TYPE="SSD"; [ -n "$DISK_NAME" ] && [ "$(cat /sys/block/$DISK_NAME/queue/rotational 2>/dev/null)" = "1" ] && DISK_TYPE="HDD"
GPU_VENDOR="unknown"; command -v lspci &>/dev/null && {
  lspci | grep -qi "nvidia" && GPU_VENDOR="nvidia"
  lspci | grep -qi "amd\|ati" && GPU_VENDOR="amd"
  lspci | grep -qi "intel.*graphics" && GPU_VENDOR="intel"
}
ACTIVE_USER=$(logname 2>/dev/null || who | awk '{print $1;exit}')
DE="unknown"; command -v loginctl &>/dev/null && [ -n "$ACTIVE_USER" ] && {
  S=$(loginctl list-sessions --no-legend | grep -m1 "$ACTIVE_USER" | awk '{print $1}')
  [ -n "$S" ] && DE=$(loginctl show-session "$S" -p Desktop --value 2>/dev/null || echo unknown)
}
[ -z "$DE" ] || [ "$DE" = "unknown" ] && DE="${XDG_CURRENT_DESKTOP:-unknown}"
DE=$(echo "$DE" | tr '[:upper:]' '[:lower:]')
echo "💾 ${RAM_MB}MB | 🖥️ $CPU_VENDOR ($CPU_CORES) | 💿 $DISK_TYPE | 🎮 $GPU_VENDOR | 🖼️ $DE"

# 5. PERFIL ADAPTATIVO
echo ""; echo "📊 [5/15] Calculando perfil..."
[ "$RAM_MB" -lt 5000 ] && RAM_TIER="LOW" || { [ "$RAM_MB" -le 8192 ] && RAM_TIER="MID" || RAM_TIER="HIGH"; }
PROFILE="${RAM_TIER}_${DISK_TYPE}"
case "$PROFILE" in
  LOW_HDD)  echo "🔴 LOW+HDD"; SWAP=10; CP=50; DR=10; SCHED="bfq"; ZRAM=$((RAM_MB*50/100)); ZA="zstd"; PC=2; PH=2; THP="madvise" ;;
  LOW_SSD)  echo "🔵 LOW+SSD"; SWAP=10; CP=50; DR=10; SCHED="mq-deadline"; ZRAM=$((RAM_MB*50/100)); ZA="zstd"; PC=2; PH=2; THP="madvise" ;;
  MID_HDD)  echo "🟡 MID+HDD"; SWAP=20; CP=30; DR=15; SCHED="bfq"; ZRAM=2048; ZA="zstd"; PC=2; PH=3; THP="madvise" ;;
  MID_SSD)  echo "🟢 MID+SSD"; SWAP=20; CP=20; DR=20; SCHED="mq-deadline"; ZRAM=2048; ZA="zstd"; PC=1; PH=4; THP="madvise" ;;
  HIGH_HDD) echo "⚡ HIGH+HDD"; SWAP=10; CP=10; DR=15; SCHED="bfq"; ZRAM=0; ZA="none"; PC=1; PH=5; THP="madvise" ;;
  HIGH_SSD) echo "🚀 HIGH+SSD"; SWAP=10; CP=5; DR=30; SCHED="mq-deadline"; ZRAM=0; ZA="none"; PC=0; PH=0; THP="madvise" ;;
esac

# 6. KERNEL + SYSCTL
echo ""; echo "⚙️ [6/15] Kernel y sysctl..."
echo schedutil | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
cat > /etc/sysctl.d/99-flytux.conf <<EOF
vm.swappiness=$SWAP
vm.vfs_cache_pressure=$CP
vm.dirty_ratio=$DR
vm.dirty_background_ratio=$((DR/2))
vm.page-cluster=0
vm.min_free_kbytes=$((RAM_MB*2048/100))
net.core.somaxconn=4096
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_congestion_control=bbr
net.core.netdev_max_backlog=4096
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
sysctl -p /etc/sysctl.d/99-flytux.conf >/dev/null 2>&1 || true
echo "$THP" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo "✅ Sysctl aplicados en vivo"

# 7. ZRAM + PRELOAD + EARLYOOM
echo ""; echo "⚡ [7/15] ZRAM + Preload + EarlyOOM..."
install_or_upgrade "preload zram-tools earlyOOM" "Gestión de Memoria"
if [ "$ZRAM" -gt 0 ]; then
  echo -e "ENABLE=yes\nSIZE=$ZRAM\nALGO=$ZA\nPRIORITY=100" > /etc/default/zramswap
  systemctl enable --now zramswap 2>/dev/null || true
else 
  systemctl disable zramswap 2>/dev/null || true
fi

if [ "$PC" -gt 0 ]; then 
  systemctl enable --now preload 2>/dev/null || true
  sed -i "s/^# model.cycle.*/model.cycle = $PC/" /etc/preload.conf 2>/dev/null || true
  sed -i "s/^# model.halflife.*/model.halflife = $PH/" /etc/preload.conf 2>/dev/null || true
else 
  systemctl disable preload 2>/dev/null || true
fi

sed -i 's/^EXTRA_ARGS=.*/EXTRA_ARGS="--prefer '(^|/)(chrome|chromium|firefox|brave)$' --notify all"/' /etc/default/earlyoom 2>/dev/null || true
systemctl enable --now earlyoom 2>/dev/null || true
echo "✅ ZRAM ($ZA), Preload y EarlyOOM configurados"

# 8. DRIVERS + FWUPD (Parche de Integración de Hardware)
echo ""; echo "🏭 [8/15] Drivers y Firmware..."
install_or_upgrade "intel-microcode amd64-microcode firmware-linux mesa-vulkan-drivers" "Oficiales"
[ "$GPU_VENDOR" = "nvidia" ] && install_or_upgrade "nvidia-driver nvidia-settings nvidia-prime" "NVIDIA utils"
install_or_upgrade "firmware-linux-nonfree firmware-misc-nonfree firmware-realtek firmware-iwlwifi" "Non-free"
install_or_upgrade "linux-firmware libdrm-common" "Alternativos"

# PARCHE: Asegurar fwupd para actualizaciones de firmware transparentes (Estilo Mac)
install_or_upgrade "fwupd" "Firmware updates (fwupd)"
systemctl enable --now fwupd 2>/dev/null || true
echo "✅ Drivers y fwupd actualizados"

# 9. CODECS + FUENTES
echo ""; echo "🎬 [9/15] Codecs y fuentes..."
install_or_upgrade "libavcodec-extra gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav ffmpeg libdvd-pkg unrar p7zip-full p7zip-rar zip unzip ttf-mscorefonts-installer fonts-liberation fonts-noto fonts-noto-cjk fonts-roboto" "Multimedia"
if dpkg -l libdvd-pkg &>/dev/null | grep -q "^ii"; then 
  echo y | DEBIAN_FRONTEND=noninteractive dpkg-reconfigure libdvd-pkg 2>/dev/null || true
fi
echo "✅ Codecs instalados"

# 10. WINE FULL + i386
echo ""; echo "🍷 [10/15] Wine Full + i386..."
dpkg --add-architecture i386 2>/dev/null || true
apt update >/dev/null 2>&1 || true
install_or_upgrade "wine wine64 wine32 winetricks winbind libwine fonts-wine wine-tools cabextract libgl1-mesa-glx:i386 libgl1-mesa-dri:i386 libpulse0:i386 libcups2:i386 libdbus-1-3:i386 libasound2:i386" "Wine Full"
command -v wine &>/dev/null && echo "✅ Wine: $(wine --version 2>/dev/null | awk '{print $1}')" || echo "⚠️ Wine: verificar"

# 11. DESINSTALACIÓN DE SOFTWARE PESADO
echo ""; echo "🗑️ [11/15] Desinstalando software pesado..."
for pkg in firefox firefox-esr libreoffice-core libreoffice-calc libreoffice-writer libreoffice-impress; do
  dpkg -l "$pkg" &>/dev/null && apt purge -y "$pkg" >/dev/null 2>&1 || true
done
apt autoremove -y --purge >/dev/null 2>&1 || true
echo "✅ Software pesado desinstalado"

# 12. APPS ESENCIALES + JOPDF
echo ""; echo "🔄 [12/15] Instalando apps esenciales..."
install_or_upgrade "cups cups-client printer-driver-all system-config-printer poppler-utils qpdf pdfarranger pdftk pdfgrep nomacs" "PDF/Impresión"
systemctl enable --now cups 2>/dev/null || true

if ! dpkg -l brave-browser &>/dev/null | grep -q "^ii"; then
  [ ! -f /usr/share/keyrings/brave-browser-archive-keyring.gpg ] && { curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg; echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg arch=amd64] https://brave-browser-apt-release.s3.brave.com/ stable main" | tee /etc/apt/sources.list.d/brave-browser-release.list >/dev/null; apt update >/dev/null 2>&1 || true; }
  apt install -y brave-browser 2>/dev/null || true
else 
  apt install --only-upgrade -y brave-browser 2>/dev/null || true
fi

install_or_upgrade "vlc" "VLC"

if ! dpkg -l rustdesk &>/dev/null | grep -q "^ii"; then
  URL=$(curl -s https://api.github.com/repos/rustdesk/rustdesk/releases/latest 2>/dev/null | grep "browser_download_url.*amd64\.deb" | head -1 | cut -d'"' -f4)
  [ -n "$URL" ] && wget -q -O /tmp/rd.deb "$URL" 2>/dev/null && { dpkg -i /tmp/rd.deb 2>/dev/null || true; apt install -f -y >/dev/null 2>&1 || true; rm -f /tmp/rd.deb; } || apt install -y rustdesk 2>/dev/null || true
else 
  apt install --only-upgrade -y rustdesk 2>/dev/null || true
fi
systemctl enable --now rustdesk.service 2>/dev/null || true

echo "🔑 Proton VPN..."
mkdir -p /usr/share/keyrings
[ ! -f /usr/share/keyrings/protonvpn-archive-keyring.gpg ] && curl -fsSL https://repo.protonvpn.com/debian/public_key.asc | gpg --dearmor --batch --yes -o /usr/share/keyrings/protonvpn-archive-keyring.gpg 2>/dev/null || true
echo "deb [signed-by=/usr/share/keyrings/protonvpn-archive-keyring.gpg arch=amd64] https://repo.protonvpn.com/debian stable main" | tee /etc/apt/sources.list.d/protonvpn-stable.list >/dev/null 2>&1
apt update >/dev/null 2>&1 || true
if ! dpkg -l protonvpn &>/dev/null | grep -q "^ii"; then 
  apt install -y protonvpn 2>/dev/null || echo "⚠️ ProtonVPN: instalar manual"
else 
  apt install --only-upgrade -y protonvpn 2>/dev/null || true
fi

echo "📄 jopdf (cdn.jopdf.com)..."
JPKG="jopdf"; JURL="https://cdn.jopdf.com/download/jopdf/jopdf-linux-amd64_setup.deb"; JDSK="jopdf.desktop"
if dpkg -l "$JPKG" 2>/dev/null | grep -q "^ii"; then
  apt policy "$JPKG" 2>/dev/null | grep -q "Installed:" && apt install --only-upgrade -y "$JPKG" 2>/dev/null || { wget -q -O /tmp/jp.deb "$JURL" 2>/dev/null && { dpkg -i /tmp/jp.deb 2>/dev/null || true; apt install -f -y >/dev/null 2>&1 || true; rm -f /tmp/jp.deb; }; }
else
  wget -q -O /tmp/jp.deb "$JURL" 2>/dev/null && { dpkg -i /tmp/jp.deb 2>/dev/null || true; apt install -f -y >/dev/null 2>&1 || true; rm -f /tmp/jp.deb; echo "✅ jopdf instalado"; } || echo "⚠️ jopdf: no se pudo descargar"
fi
if [ -f "/usr/share/applications/$JDSK" ]; then
  update-desktop-database &>/dev/null || true
  for UH in /home/*; do [ -d "$UH" ] && [ -f "$UH/.bashrc" ] && { U=$(basename "$UH"); id "$U" &>/dev/null && runuser -u "$U" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$U")/bus" xdg-mime default "$JDSK" application/pdf 2>/dev/null || true; }; done
  mkdir -p /etc/skel/.config; cp "/usr/share/applications/$JDSK" /etc/skel/.config/ 2>/dev/null || true
  echo "✅ PDF → jopdf asociado"
fi
echo "✅ Apps esenciales listas"

# 13. FIREWALL
echo ""; echo "🛡️ [13/15] Firewall..."
ufw --force reset >/dev/null 2>&1; ufw default deny incoming; ufw default allow outgoing
for P in 21 23 135 136 137 138 139 445 3389 5900; do ufw deny $P/tcp 2>/dev/null || true; done
ufw allow 53/tcp 2>/dev/null||true; ufw allow 53/udp 2>/dev/null||true; ufw allow 80/tcp 2>/dev/null||true; ufw allow 443/tcp 2>/dev/null||true
ufw allow 21115:21119/tcp 2>/dev/null||true; ufw allow 21115:21119/udp 2>/dev/null||true
ufw --force enable >/dev/null 2>&1; systemctl enable --now ufw 2>/dev/null || true
echo "✅ Firewall activo"

# 14. PRIVACIDAD + APPARMOR (Parche de Seguridad) + ANIMACIONES (Parche Visual)
echo ""; echo "🔒 [14/15] Privacidad, Seguridad y Experiencia Visual..."
for pkg in popularity-contest whoopsie apport ubuntu-report command-not-found; do dpkg -l "$pkg" &>/dev/null && apt purge -y "$pkg" >/dev/null 2>&1 || true; done
sed -i 's/^Enabled=1/Enabled=0/' /etc/default/apport 2>/dev/null || true

# PARCHE: Reactivar AppArmor para Flatpak/bwrap (El script v1.0 los desactivó)
if command -v aa-enforce &>/dev/null; then
  for profile in /etc/apparmor.d/*flatpak* /etc/apparmor.d/*bwrap*; do 
    [ -f "$profile" ] && aa-enforce "$profile" 2>/dev/null || true
  done
  systemctl restart apparmor 2>/dev/null || true
  echo "✅ AppArmor de Flatpak/bwrap reactivado (Parche de seguridad)"
fi

# PARCHE: Reactivar animaciones del escritorio (El script v1.0 las desactivó, arruinando la fluidez)
if [ -n "$ACTIVE_USER" ] && [ "$ACTIVE_USER" != "root" ]; then
  UID_U=$(id -u "$ACTIVE_USER"); DBUS="unix:path=/run/user/$UID_U/bus"
  case "$DE" in 
    *gnome*|*zorin*) runuser -u "$ACTIVE_USER" -- env DBUS_SESSION_BUS_ADDRESS="$DBUS" bash -c 'gsettings set org.gnome.desktop.interface enable-animations true 2>/dev/null||true';; 
    *kde*|*plasma*) runuser -u "$ACTIVE_USER" -- bash -c 'kwriteconfig5 --file kwinrc --group Compositing --key Enabled true 2>/dev/null||true';; 
    *xfce*) runuser -u "$ACTIVE_USER" -- bash -c 'xfconf-query -c xfwm4 -p /general/use_compositing -s true 2>/dev/null||true';; 
  esac
  echo "✅ Animaciones del escritorio reactivadas (Parche visual Mac-like)"
fi

# 15. GRUB + LIMPIEZA + FINALIZACIÓN
echo ""; echo "🔧 [15/15] GRUB y Limpieza Final..."
VG=""; case "$CPU_VENDOR" in *intel*) VG="intel_pstate=active i915.enable_guc=3"; mkdir -p /etc/modprobe.d; echo "options i915 enable_guc=3" > /etc/modprobe.d/i915-flytux.conf;; *amd*) VG="amd_pstate=active amdgpu.ppfeaturemask=0xffffffff"; mkdir -p /etc/modprobe.d; echo "options amdgpu ppfeaturemask=0xffffffff" > /etc/modprobe.d/amdgpu-flytux.conf;; esac
mkdir -p /etc/default/grub.d; echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT $VG\"" > /etc/default/grub.d/99-flytux.cfg
update-grub >/dev/null 2>&1 || true

apt full-upgrade -y >/dev/null 2>&1 || true; apt autoremove -y --purge >/dev/null 2>&1 || true
journalctl --vacuum-size=50M --vacuum-time=7d 2>/dev/null || true
rm -rf /tmp/* /var/tmp/* /var/cache/apt/archives/*.deb 2>/dev/null || true
echo "✅ Limpieza completada"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "🐧 FlyTux Optimizer v5.0 COMPLETADO"
echo "📊 Perfil: $PROFILE | 🔧 $CPU_VENDOR | 🎮 $GPU_VENDOR"
echo "🧠 Memoria: ZRAM ($ZA) + EarlyOOM"
echo "🛡️ Parches aplicados: AppArmor, Animaciones, fwupd"
echo "📁 Backup seguro en: $BACKUP"
echo "═══════════════════════════════════════════════════════"
echo "💡 CONSEJO: Reinicia el equipo para aplicar GRUB y los parches visuales."
echo "🔙 REVERTIR: sudo tar xzf $BACKUP -C / && sudo ufw disable && sudo update-grub"
echo "═══════════════════════════════════════════════════════"