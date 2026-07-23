#!/usr/bin/env bash
#=============================================================================
# 🐧 FlyTux v25.0 - Sistema Cognitivo Cooperativo (Definitive Edition)
# Arquitectura: core objetivo + instalador conservador + daemon hardened
# Correcciones: gestión de errores, JSON seguro, score ponderado,
# daemon con flock+watchdog, instalador sin decisiones opinables
#=============================================================================

set -Eeuo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURACIÓN GLOBAL
# ═══════════════════════════════════════════════════════════════════════════

FX="/etc/flytux"
FV="/var/lib/flytux"
LOG="/var/log/flytux-$(date +%F-%H%M).log"
BKP="/var/backups/flytux-$(date +%F).tar.gz"
ERRORS=()
WARNINGS=()

# ═══════════════════════════════════════════════════════════════════════════
# HELPERS DE LOGGING (reemplazan echo repetidos)
# ═══════════════════════════════════════════════════════════════════════════

log()   { echo "✅ $*"; logger -t flytux "$*"; }
info()  { echo "ℹ️  $*"; }
warn()  { echo "⚠️  $*" >&2; WARNINGS+=("$*"); logger -t flytux "WARN: $*"; }
error() { echo "❌ $*" >&2; ERRORS+=("$*"); logger -t flytux "ERROR: $*"; }
fatal() { echo "💀 $*" >&2; logger -t flytux "FATAL: $*"; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════
# GESTIÓN DE ERRORES (run wrapper)
# ═══════════════════════════════════════════════════════════════════════════

run() {
  # Ejecuta un comando y captura errores sin abortar
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    return 0
  else
    local rc=$?
    error "[$desc] falló (rc=$rc): $*"
    return $rc
  fi
}

run_visible() {
  # Como run pero muestra salida (para apt update, etc.)
  local desc="$1"; shift
  if "$@"; then
    return 0
  else
    local rc=$?
    error "[$desc] falló (rc=$rc): $*"
    return $rc
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# HELPERS DE PAQUETES Y SERVICIOS
# ═══════════════════════════════════════════════════════════════════════════

pkg_exists() { apt-cache madison "$1" 2>/dev/null | grep -q '|'; }

inst() {
  local desc="$1"; shift
  info "📦 $desc: $*"
  if run "inst:$desc" apt install -y "$@"; then
    log "$desc instalado"
  else
    warn "$desc: algunos paquetes fallaron"
  fi
}

svc_on() {
  systemctl list-unit-files "$1.service" &>/dev/null | grep -q "$1" || return 0
  run "svc_on:$1" systemctl enable --now "$1"
}

svc_off() {
  systemctl list-unit-files "$1.service" &>/dev/null | grep -q "$1" || return 0
  run "svc_off:$1" systemctl disable --now "$1"
}

# ═══════════════════════════════════════════════════════════════════════════
# JSON SEGURO (escape automático)
# ═══════════════════════════════════════════════════════════════════════════

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  echo "$s"
}

json_write() {
  # Uso: json_write archivo key1 value1 key2 value2 ...
  local file="$1"; shift
  local json="{"
  local first=true
  while [ $# -ge 2 ]; do
    local key="$1" val="$2"; shift 2
    $first || json+=","
    first=false
    # Detectar si es boolean, número o string
    if [[ "$val" == "true" || "$val" == "false" || "$val" =~ ^[0-9]+$ ]]; then
      json+="\"$key\":$val"
    else
      json+="\"$key\":\"$(json_escape "$val")\""
    fi
  done
  json+="}"
  echo "$json" > "$file"
}

# ═══════════════════════════════════════════════════════════════════════════
# DETECCIÓN DE CPU (lectura única + lscpu -J si disponible)
# ═══════════════════════════════════════════════════════════════════════════

read_cpuinfo() {
  # Leer /proc/cpuinfo UNA sola vez con awk
  eval "$(awk -F: '
    /^vendor_id/ && !v {gsub(/^[ \t]+|[ \t]+$/, "", $2); print "CV=" tolower($2); v=1}
    /^cpu family/ && !f {gsub(/^[ \t]+|[ \t]+$/, "", $2); print "CF=" $2; f=1}
    /^model[ \t]*:/ && !m {gsub(/^[ \t]+|[ \t]+$/, "", $2); print "CM=" $2; m=1}
    /^stepping/ && !s {gsub(/^[ \t]+|[ \t]+$/, "", $2); print "CS=" $2; s=1}
    /^model name/ && !n {gsub(/^[ \t]+|[ \t]+$/, "", $2); print "CN=\"" $2 "\""; n=1}
    /^flags/ && !fl {gsub(/^[ \t]+|[ \t]+$/, "", $2); print "FLG=\"" $2 "\""; fl=1}
  ' /proc/cpuinfo)"
  
  CC=$(nproc)
  AVX2=$(echo "$FLG" | grep -qw avx2 && echo true || echo false)
  AVX512=$(echo "$FLG" | grep -qw avx512f && echo true || echo false)
  
  # Frecuencia máxima: cpufreq > lscpu -J > lscpu
  CPU_MAX_MHZ=0
  if [ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]; then
    CPU_MAX_MHZ=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq) / 1000 ))
  elif command -v lscpu &>/dev/null; then
    # Intentar lscpu -J (JSON) primero
    if lscpu -J &>/dev/null; then
      CPU_MAX_MHZ=$(lscpu -J 2>/dev/null | awk -F'"' '/CPU max MHz/{for(i=1;i<=NF;i++) if($i=="CPU max MHz") print $(i+4)}' | tr -d ' ,')
    fi
    [ -z "$CPU_MAX_MHZ" ] || [ "$CPU_MAX_MHZ" -eq 0 ] && \
      CPU_MAX_MHZ=$(lscpu 2>/dev/null | awk '/CPU max MHz/{printf "%d",$4}')
  fi
  [ -z "$CPU_MAX_MHZ" ] || [ "$CPU_MAX_MHZ" -eq 0 ] && CPU_MAX_MHZ=2000
  
  # CPU híbrida: topología real
  HYB=false
  CAPS=$(cat /sys/devices/system/cpu/cpu*/cpu_capacity 2>/dev/null | sort -u | wc -l)
  [ "$CAPS" -gt 1 ] && HYB=true
}

# ═══════════════════════════════════════════════════════════════════════════
# BASE CPUID (sin duplicados, amplia)
# ═══════════════════════════════════════════════════════════════════════════

detect_cpu_generation() {
  CG="unknown"; TLE=100
  
  if [[ "$CV" == *"intel"* && "$CF" == "6" ]]; then
    case "$CM" in
      # Intel Core modernos (2023-2025)
      198) CG="ArrowLake-S"; TLE=105;;
      185) CG="LunarLake"; TLE=105;;
      183) CG="ArrowLake-H"; TLE=105;;
      173) CG="MeteorLake"; TLE=105;;
      170|171) CG="RaptorLake-R"; TLE=100;;
      167) CG="RocketLake"; TLE=100;;
      158|165) CG="RaptorLake"; TLE=100;;
      151|154|155) CG="AlderLake"; TLE=100;;
      140|141) CG="TigerLake"; TLE=100;;
      142) CG="KabyLake-R"; TLE=100;;  # Único, sin duplicado
      126) CG="CometLake-U"; TLE=100;;
      125) CG="IceLake-Y"; TLE=100;;
      102) CG="CannonLake"; TLE=100;;
      150) CG="AlderLake-N"; TLE=105;;
      166) CG="CometLake-H"; TLE=100;;
      162) CG="CoffeeLake-R"; TLE=100;;
      152) CG="CoffeeLake"; TLE=100;;
      122) CG="GeminiLake"; TLE=105;;
      92) CG="ApolloLake"; TLE=105;;
      78|94) CG="Skylake"; TLE=100;;
      61|71) CG="Broadwell"; TLE=100;;
      60|69|70) CG="Haswell"; TLE=100;;
      58) CG="IvyBridge"; TLE=105;;
      42) CG="SandyBridge"; TLE=100;;
      37|44|53) CG="Westmere"; TLE=105;;
      26|30|31|46) CG="Nehalem"; TLE=100;;
      23|29) CG="Penryn"; TLE=105;;
      15) CG="Merom"; TLE=100;;
      *) CG="Intel-F6-M$CM";;
    esac
  elif [[ "$CV" == *"amd"* ]]; then
    case "$CF" in
      26) CG="Zen5"; TLE=95;;
      25)
        if [ "$CM" -ge 112 ] 2>/dev/null; then CG="Zen4-Dragon"; TLE=95
        elif [ "$CM" -ge 96 ] 2>/dev/null; then CG="Zen4-Phoenix"; TLE=95
        elif [ "$CM" -ge 80 ] 2>/dev/null; then CG="Zen4-Raphael"; TLE=95
        elif [ "$CM" -ge 64 ] 2>/dev/null; then CG="Zen3+-Rembrandt"; TLE=95
        elif [ "$CM" -ge 32 ] 2>/dev/null; then CG="Zen3-Vermeer"; TLE=90
        elif [ "$CM" -ge 16 ] 2>/dev/null; then CG="Zen3-Cezanne"; TLE=90
        else CG="Zen3"; TLE=90; fi;;
      23)
        if [ "$CM" -ge 112 ] 2>/dev/null; then CG="Zen2-Vermeer"; TLE=95
        elif [ "$CM" -ge 96 ] 2>/dev/null; then CG="Zen2-Matisse"; TLE=95
        elif [ "$CM" -ge 48 ] 2>/dev/null; then CG="Zen2-Renoir"; TLE=95
        elif [ "$CM" -ge 16 ] 2>/dev/null; then CG="Zen+-Picasso"; TLE=95
        else CG="Zen-Summit"; TLE=95; fi;;
      21) CG="Bulldozer/Piledriver"; TLE=90;;
      *) CG="AMD-F$CF";;
    esac
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# GPU (lspci cacheado en 2 variables)
# ═══════════════════════════════════════════════════════════════════════════

cache_lspci() {
  # Cachear lspci UNA sola vez en dos variables
  LSPCI_NN=$(lspci -nn 2>/dev/null || echo "")
  LSPCI_NNK=$(lspci -nnk 2>/dev/null || echo "")
}

detect_gpu() {
  GV=""; HI=false; HA=false; HN=false; GC=0; PD="unknown"
  
  if [ -n "$LSPCI_NN" ]; then
    echo "$LSPCI_NN" | grep -iE "vga|3d|display" | grep -q "\[8086:" && { GV+="intel,"; HI=true; GC=$((GC+1)); }
    echo "$LSPCI_NN" | grep -iE "vga|3d|display" | grep -q "\[1002:" && { GV+="amd,"; HA=true; GC=$((GC+1)); }
    echo "$LSPCI_NN" | grep -iE "vga|3d|display" | grep -q "\[10de:" && { GV+="nvidia,"; HN=true; GC=$((GC+1)); }
    [ "$GC" -gt 1 ] && HYB_GPU=true || HYB_GPU=false
    PD=$(echo "$LSPCI_NNK" | grep -i "vga compatible controller" -A2 | grep "Kernel driver in use:" | awk '{print $4}' | tr A-Z a-z | head -1)
    [ -z "$PD" ] && PD=$(echo "$LSPCI_NNK" | grep -i "3d controller" -A2 | grep "Kernel driver in use:" | awk '{print $4}' | tr A-Z a-z | head -1)
    [ -z "$PD" ] && PD="unknown"
  fi
  GV="${GV%,}"; [ -z "$GV" ] && GV="unknown"
}

get_gpu_score() {
  local GPU_ID=$(echo "$LSPCI_NN" | grep -iE "vga|3d" | head -1 | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' | tr -d '[]')
  case "$GPU_ID" in
    10de:2f*|10de:2e*) echo 20;;  # Blackwell
    10de:26*|10de:27*) echo 18;;  # Ada
    10de:22*|10de:24*) echo 16;;  # Ampere
    10de:1e*|10de:1f*) echo 14;;  # Turing
    10de:1b*|10de:1c*) echo 10;;  # Pascal
    1002:74*|1002:75*) echo 18;;  # RDNA3
    1002:73*|1002:69*) echo 15;;  # RDNA2
    1002:73[0-2]*|1002:6[6-7]*) echo 12;;  # RDNA1
    8086:56*) echo 14;;  # Arc
    *) echo 6;;  # Integrada
  esac
}

# ═══════════════════════════════════════════════════════════════════════════
# DETECCIÓN RESTANTE
# ═══════════════════════════════════════════════════════════════════════════

detect_storage() {
  DN=$(lsblk -ndo pkname "$(df -P / | awk 'NR==2{print $1}')" 2>/dev/null | head -1)
  DT="hdd"; [ -n "$DN" ] && [ "$(cat /sys/block/$DN/queue/rotational 2>/dev/null)" = "0" ] && DT="ssd"
  echo "$DN" | grep -qi nvme && DT="nvme"
  TRIM=false; [ "$DT" != "hdd" ] && lsblk --discard "/dev/$DN" 2>/dev/null | tail -1 | grep -qE "yes|1" && TRIM=true
}

detect_peripherals() {
  BT=false
  lsusb 2>/dev/null | grep -qi bluetooth && BT=true
  [ "$BT" = "false" ] && [ -n "$LSPCI_NN" ] && echo "$LSPCI_NN" | grep -qi bluetooth && BT=true
  [ "$BT" = "false" ] && command -v hciconfig &>/dev/null && hciconfig 2>/dev/null | grep -q hci && BT=true
  MD=$(lsusb 2>/dev/null | grep -qiE "modem|lte|4g|5g" && echo true || echo false)
  PR=$(lpstat -p 2>/dev/null | grep -q printer && echo true || echo false)
  SN=false; command -v sensors &>/dev/null && sensors 2>/dev/null | grep -qE "Core|Tctl|Package" && SN=true
}

detect_system() {
  RAM=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
  SWAP=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
  LAPTOP=$(ls /sys/class/power_supply/BAT* &>/dev/null && echo true || echo false)
  BOOT=$([ -d /sys/firmware/efi ] && echo uefi || echo bios)
  SB="unknown"; command -v mokutil &>/dev/null && { mokutil --sb-state 2>/dev/null | grep -q "enabled" && SB="on"; mokutil --sb-state 2>/dev/null | grep -q "disabled" && SB="off"; }
  AU=$(logname 2>/dev/null || who | awk '{print $1;exit}')
  DE="${XDG_CURRENT_DESKTOP:-unknown}"; DE=$(echo "$DE" | tr A-Z a-z)
  
  AM=""
  systemctl is-active -q power-profiles-daemon 2>/dev/null && AM+="ppd,"
  systemctl is-active -q tlp 2>/dev/null && AM+="tlp,"
  systemctl is-active -q thermald 2>/dev/null && AM+="thermald,"
  AM="${AM%,}"; [ -z "$AM" ] && AM="none"
  FM=$([ "$AM" = "none" ] && echo "exclusive" || echo "cooperative")
}

# ═══════════════════════════════════════════════════════════════════════════
# HAL FUNCTIONS (usadas por daemon y score)
# ═══════════════════════════════════════════════════════════════════════════

thermal_get_temp() {
  local T=0
  for H in /sys/class/hwmon/hwmon*/temp1_input; do
    [ -f "$H" ] || continue
    LABEL=$(cat "${H%temp1_input}/name" 2>/dev/null)
    case "$LABEL" in coretemp*|k10temp*|cpu*|zen*|acpitz*) ;; *) continue;; esac
    V=$(cat "$H" 2>/dev/null); V=$((V/1000))
    [ "$V" -gt "$T" ] && T=$V
  done
  if [ "$T" -eq 0 ]; then
    for Z in /sys/class/thermal/thermal_zone*; do
      [ -d "$Z" ] || continue
      TYPE=$(cat "$Z/type" 2>/dev/null)
      case "$TYPE" in x86_pkg_temp*|k10temp*|coretemp*|cpu_thermal*) ;; *) continue;; esac
      V=$(cat "$Z/temp" 2>/dev/null); V=$((V/1000))
      [ "$V" -gt "$T" ] && T=$V
    done
  fi
  echo "$T"
}

thermal_get_limit() {
  local L=0
  for H in /sys/class/hwmon/hwmon*/temp1_crit; do
    [ -f "$H" ] || continue
    V=$(cat "$H" 2>/dev/null); V=$((V/1000))
    [ "$V" -ge 70 ] && [ "$V" -le 115 ] && [ "$V" -gt "$L" ] && L=$V
  done
  [ "$L" -eq 0 ] && L=${TLE:-100}
  [ -z "$L" ] || [ "$L" -eq 0 ] && L=100
  echo "$L"
}

thermal_profile() {
  local T=$(thermal_get_temp) L=$(thermal_get_limit) P=$((T*100/L))
  if [ "$P" -lt 75 ]; then echo performance
  elif [ "$P" -lt 88 ]; then echo balanced
  else echo powersave; fi
}

cpu_set_governor() {
  local REQ="$1" NOW=$(date +%s)
  local SF="/var/lib/flytux/history/cpu-state"
  [ -f "$SF" ] && { LAST=$(cut -d'|' -f1 "$SF"); LC=$(cut -d'|' -f2 "$SF"); }
  [ "$LAST" = "$REQ" ] && return
  [ $((NOW - ${LC:-0})) -lt 120 ] && return  # histéresis 120s
  
  local DRV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null)
  local GOV="schedutil"
  case "$DRV" in
    intel_pstate|amd_pstate*)
      case "$REQ" in performance) GOV="performance";; *) GOV="powersave";; esac;;
    *)
      case "$REQ" in performance) GOV="performance";; balanced) GOV="schedutil";; powersave|silent) GOV="powersave";; esac;;
  esac
  grep -q "$GOV" /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || return
  echo "$GOV" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor &>/dev/null || true
  echo "${REQ}|${NOW}" > "$SF"
  logger -t flytux "gov=$GOV ($REQ) drv=$DRV"
}

gpu_set_mode() {
  local MODE="$1"
  if command -v prime-select &>/dev/null; then
    case "$MODE" in
      integrated) prime-select intel 2>/dev/null || prime-select amd 2>/dev/null;;
      nvidia)     prime-select nvidia 2>/dev/null;;
      on-demand)  prime-select on-demand 2>/dev/null;;
    esac
  elif command -v envycontrol &>/dev/null; then
    case "$MODE" in
      integrated) envycontrol -s integrated 2>/dev/null;;
      nvidia)     envycontrol -s nvidia 2>/dev/null;;
      hybrid)     envycontrol -s hybrid 2>/dev/null;;
    esac
  fi
}

battery_get_source() {
  for P in /sys/class/power_supply/*/type; do
    [ -f "$P" ] && grep -q Mains "$P" 2>/dev/null && [ "$(cat "${P%type}online" 2>/dev/null)" = "1" ] && { echo ac; return; }
  done
  echo battery
}

battery_get_percent() {
  for C in /sys/class/power_supply/BAT*/capacity; do
    [ -f "$C" ] && { cat "$C"; return; }
  done
  echo 100
}

battery_apply_profile() {
  local S=$(battery_get_source) B=$(battery_get_percent) G="balanced" GM="on-demand"
  [ "$S" = "battery" ] && { G="powersave"; GM="integrated"; }
  cpu_set_governor "$G"
  gpu_set_mode "$GM"
  logger -t flytux "power=$S batt=$B gov=$G gpu=$GM"
}

# ═══════════════════════════════════════════════════════════════════════════
# SCORE PONDERADO (CPU 35, RAM 20, GPU 20, Disco 10, Instr 5, Gen 5, Temp 5)
# ═══════════════════════════════════════════════════════════════════════════

score_calculate() {
  local S_CPU=0 S_RAM=0 S_GPU=0 S_DISK=0 S_INST=0 S_GEN=0 S_TEMP=0
  
  # CPU (35 pts): cores + freq + híbrido
  local cpu_pts=0
  cpu_pts=$((CC > 24 ? 20 : CC > 16 ? 17 : CC > 12 ? 14 : CC > 8 ? 11 : CC > 4 ? 7 : 3))
  cpu_pts=$((cpu_pts + (CPU_MAX_MHZ > 5000 ? 10 : CPU_MAX_MHZ > 4000 ? 8 : CPU_MAX_MHZ > 3000 ? 5 : 2)))
  $HYB && cpu_pts=$((cpu_pts + 5))
  [ "$cpu_pts" -gt 35 ] && cpu_pts=35
  S_CPU=$cpu_pts
  
  # RAM (20 pts)
  S_RAM=$((RAM > 32768 ? 20 : RAM > 16384 ? 17 : RAM > 8192 ? 13 : RAM > 4096 ? 8 : 4))
  
  # GPU (20 pts)
  S_GPU=$(get_gpu_score)
  [ "$S_GPU" -gt 20 ] && S_GPU=20
  
  # Disco (10 pts)
  echo "$DN" | grep -qi nvme && S_DISK=10 || \
    { [ -n "$DN" ] && [ "$(cat /sys/block/$DN/queue/rotational 2>/dev/null)" = "0" ] && S_DISK=6; }
  
  # Instrucciones (5 pts)
  echo "$FLG" | grep -qw avx512f && S_INST=5 || \
    { echo "$FLG" | grep -qw avx2 && S_INST=3; } || S_INST=1
  
  # Generación (5 pts)
  case "$CG" in
    *Zen5*|*Lunar*|*Arrow*|*Meteor*) S_GEN=5;;
    *Zen4*|*Raptor*|*Alder*) S_GEN=4;;
    *Zen3*|*Tiger*|*Rocket*) S_GEN=3;;
    *Zen2*|*Ice*|*Comet*) S_GEN=2;;
    *) S_GEN=1;;
  esac
  
  # Temperatura (5 pts): más frío = mejor
  local TEMP=$(thermal_get_temp 2>/dev/null)
  [ -n "$TEMP" ] && [ "$TEMP" -gt 0 ] && {
    [ "$TEMP" -lt 50 ] && S_TEMP=5 || \
    [ "$TEMP" -lt 65 ] && S_TEMP=4 || \
    [ "$TEMP" -lt 80 ] && S_TEMP=2 || S_TEMP=1
  } || S_TEMP=3
  
  local TOTAL=$((S_CPU + S_RAM + S_GPU + S_DISK + S_INST + S_GEN + S_TEMP))
  [ "$TOTAL" -gt 100 ] && TOTAL=100
  
  echo "$TOTAL|$S_CPU|$S_RAM|$S_GPU|$S_DISK|$S_INST|$S_GEN|$S_TEMP"
}

# ═══════════════════════════════════════════════════════════════════════════
# DAEMON (flock + systemd watchdog + señales)
# ═══════════════════════════════════════════════════════════════════════════

daemon_main() {
  local PF="/run/flytuxd.pid" HD="/var/lib/flytux/history" LOCK="/run/lock/flytuxd.lock"
  mkdir -p "$HD" /run/lock
  
  # flock para evitar múltiples instancias
  exec 9>"$LOCK"
  if ! flock -n 9; then
    logger -t flytuxd "Otra instancia ya está corriendo"
    exit 1
  fi
  
  # Manejo de señales
  trap 'logger -t flytuxd "Daemon detenido (SIGTERM)"; rm -f "$PF"; exit 0' SIGTERM SIGINT
  trap 'logger -t flytuxd "Daemon recargado (SIGHUP)"' SIGHUP
  
  echo $$ > "$PF"
  
  # Systemd watchdog
  if [ -n "${NOTIFY_SOCKET:-}" ]; then
    systemd-notify --ready 2>/dev/null || true
  fi
  
  # Cargar configuración
  FM=$(grep -o '"mode":"[^"]*"' /etc/flytux/hw.json 2>/dev/null | cut -d'"' -f4)
  [ -z "$FM" ] && FM="cooperative"
  
  logger -t flytuxd "Daemon iniciado (PID $$, modo: $FM)"
  
  LP=""; LT=""; CY=0
  while true; do
    PPD=$(systemctl is-active -q power-profiles-daemon 2>/dev/null && echo y || echo n)
    TLD=$(systemctl is-active -q thermald 2>/dev/null && echo y || echo n)
    ACT=true; [ "$FM" = "cooperative" ] && [ "$PPD" = "y" ] && ACT=false
    
    PS=$(battery_get_source)
    [ "$PS" != "$LP" ] && { $ACT && battery_apply_profile; LP="$PS"; }
    
    if [ "$TLD" = "n" ] || [ "$FM" = "exclusive" ]; then
      TP=$(thermal_profile)
      [ "$TP" != "$LT" ] && { cpu_set_governor "$TP"; LT="$TP"; }
    fi
    
    CY=$((CY+1))
    if [ "$CY" -ge 10 ]; then
      CY=0
      T=$(thermal_get_temp)
      B=$(battery_get_percent)
      RA=$(awk '/MemAvailable/{printf "%d",$2/1024}' /proc/meminfo)
      LD=$(cut -d' ' -f1 /proc/loadavg)
      echo "$(date -Iseconds)|t=${T:-0}|p=$PS|b=$B|r=$RA|l=$LD|g=${LT:-?}" >> "$HD/sys.log"
      [ -f "$HD/sys.log" ] && [ "$(stat -c%s "$HD/sys.log" 2>/dev/null)" -gt 1048576 ] && tail -1000 "$HD/sys.log" > "$HD/sys.log.tmp" && mv "$HD/sys.log.tmp" "$HD/sys.log"
      
      # Watchdog ping
      [ -n "${NOTIFY_SOCKET:-}" ] && systemd-notify WATCHDOG=1 2>/dev/null || true
    fi
    sleep 30
  done
}

# ═══════════════════════════════════════════════════════════════════════════
# INSTALADOR (conservador, sin decisiones opinables)
# ═══════════════════════════════════════════════════════════════════════════

install_flytux() {
  echo "🐧 FlyTux v25.0 - Instalando..."
  [ "$(id -u)" -ne 0 ] && fatal "Ejecutar con: sudo bash $0"
  
  . /etc/os-release
  [[ "$ID_LIKE" =~ debian|ubuntu || "$ID" =~ debian|ubuntu|linuxmint|pop|zorin ]] || fatal "Distro incompatible"
  export DEBIAN_FRONTEND=noninteractive
  
  mkdir -p /var/backups "$FX" "$FV/history"
  exec > >(tee -a "$LOG") 2>&1
  
  # 1. Backup
  info "🔐 [1/12] Backup..."
  run "backup" tar czf "$BKP" /etc/sysctl.d /etc/default /etc/systemd/system /etc/udev/rules.d \
    /etc/modprobe.d /etc/