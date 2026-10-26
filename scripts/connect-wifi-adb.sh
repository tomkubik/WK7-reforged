#!/usr/bin/env bash
# connect-wifi-adb.sh — Discover LG WK7 on Wi-Fi (Setup Hotspot or Home LAN),
# test ADB over TCP:5555, verify model identity, check bootloader unlock status,
# and optionally switch the hardware MICOM USB mux to the external Micro-USB port.
#
# Usage:
#   ./scripts/connect-wifi-adb.sh                        # Auto-detect (Setup Hotspot 192.168.255.249 or LAN scan)
#   ./scripts/connect-wifi-adb.sh <speaker-ip>           # Probe specific IP
#   ./scripts/connect-wifi-adb.sh <speaker-ip> --switch-usb  # Also switch MICOM mux to external Micro-USB port

set -u

BOLD="\033[1m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RED="\033[1;31m"
RESET="\033[0m"

TARGET_IP=""
SWITCH_USB=0

for arg in "$@"; do
  case "$arg" in
    --switch-usb) SWITCH_USB=1 ;;
    -h|--help)
      echo "Usage: $0 [<speaker-ip>] [--switch-usb]"
      echo ""
      echo "Options:"
      echo "  <speaker-ip>   IP address of the WK7 speaker (e.g. 192.168.255.249 on Setup Hotspot,"
      echo "                 or your home router DHCP IP). If omitted, checks 192.168.255.249 and"
      echo "                 scans your local subnet."
      echo "  --switch-usb   If 'adb root' succeeds, send MICOM UART command 0xC2 0x00 0x00"
      echo "                 to switch the hardware USB mux to the bottom Micro-USB port."
      exit 0
      ;;
    *) TARGET_IP="$arg" ;;
  esac
done

echo -e "${BOLD}======================================================================${RESET}"
echo -e "${BOLD} LG WK7 — Wi-Fi Discovery, ADB Probe & USB Switcher${RESET}"
echo -e "${BOLD}======================================================================${RESET}"

# Check if an IP responds on Google Cast setup port 8008 (/setup/eureka_info)
check_cast_info() {
  local ip="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -s --connect-timeout 1 --max-time 2 "http://${ip}:8008/setup/eureka_info" 2>/dev/null || true
  fi
}

# Probe a candidate IP over Cast (8008) and ADB (5555)
probe_ip() {
  local ip="$1"
  local serial="${ip}:5555"

  echo ""
  echo -e "${CYAN}[*] Probing ${ip}...${RESET}"

  # 1. Check Cast HTTP port 8008 to confirm if speaker is reachable on Wi-Fi
  local eureka
  eureka="$(check_cast_info "$ip")"
  if [[ -n "$eureka" ]]; then
    echo -e "${GREEN}  ✓ Speaker is online on Wi-Fi at ${ip} (Cast port 8008 responded)${RESET}"
  fi

  # 2. Attempt ADB connection on TCP:5555
  local out
  out="$(adb connect "$serial" 2>&1 || true)"
  echo "  adb connect: $out"

  if echo "$out" | grep -qiE "refused|failed to connect|cannot connect|timed out"; then
    if [[ -n "$eureka" ]]; then
      echo ""
      echo -e "${YELLOW}⚠ DIAGNOSTIC RESULT:${RESET}"
      echo "  The WK7 speaker IS reachable on Wi-Fi at ${ip} (port 8008 is open),"
      echo "  but TCP port 5555 returned Connection Refused / Timed Out."
      echo "  -> This means your retail unit is running a locked consumer 'user' build"
      echo "     (ro.debuggable=0) where Android init disables adbd."
      echo "  -> See the 'Locked-Bootloader Units' section in README.md."
      return 2
    fi
    return 1
  fi

  sleep 1
  local model device boot_state verified_state build_type debuggable
  model="$(adb -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"

  if [[ -z "$model" ]]; then
    echo -e "${YELLOW}  ⚠ Connected to ${serial}, but 'adb shell' did not respond (device may be offline).${RESET}"
    adb disconnect "$serial" >/dev/null 2>&1 || true
    return 1
  fi

  # Safety check: verify ro.product.model is WK7 (other devices like Google Home answer on 5555!)
  if [[ "$model" != *WK7* ]]; then
    echo -e "${YELLOW}  ⚠ Skipping ${ip}: responded on port 5555, but model is '${model}' (not an LG WK7).${RESET}"
    adb disconnect "$serial" >/dev/null 2>&1 || true
    return 1
  fi

  device="$(adb -s "$serial" shell getprop ro.product.device 2>/dev/null | tr -d '\r')"
  boot_state="$(adb -s "$serial" shell getprop ro.boot.vbmeta.device_state 2>/dev/null | tr -d '\r')"
  verified_state="$(adb -s "$serial" shell getprop ro.boot.verifiedbootstate 2>/dev/null | tr -d '\r')"
  build_type="$(adb -s "$serial" shell getprop ro.build.type 2>/dev/null | tr -d '\r')"
  debuggable="$(adb -s "$serial" shell getprop ro.debuggable 2>/dev/null | tr -d '\r')"

  echo "----------------------------------------------------------------------"
  echo -e "${GREEN}✓ Connected to LG WK7 over Wi-Fi ADB (${serial})!${RESET}"
  echo -e "  Model:                        ${BOLD}${model}${RESET} (${device:-unknown})"
  echo -e "  ro.boot.vbmeta.device_state:  ${BOLD}${boot_state:-unknown}${RESET}"
  echo -e "  ro.boot.verifiedbootstate:    ${BOLD}${verified_state:-unknown}${RESET}"
  echo -e "  ro.build.type:                ${BOLD}${build_type:-unknown}${RESET} (ro.debuggable=${debuggable:-?})"
  echo "----------------------------------------------------------------------"

  if [[ "$boot_state" == "unlocked" || "$verified_state" == "orange" ]]; then
    echo -e "${GREEN}>>> RESULT: UNLOCKED BOOTLOADER!${RESET}"
    echo "    Use the main folder: WK7-software-for-unlocked-bootloader/"
  else
    echo -e "${YELLOW}>>> RESULT: LOCKED BOOTLOADER (${verified_state:-locked})${RESET}"
    echo "    Use the experimental folder: WK7-software-for-locked-bootloader-EXPERIMENTAL/"
  fi

  if [[ "$SWITCH_USB" -eq 1 ]]; then
    echo ""
    echo -e "${CYAN}[*] Attempting 'adb root' to switch MICOM hardware USB mux to external Micro-USB port...${RESET}"
    adb -s "$serial" root >/dev/null 2>&1 || true
    sleep 2
    adb connect "$serial" >/dev/null 2>&1 || true
    local uid
    uid="$(adb -s "$serial" shell id -u 2>/dev/null | tr -d '\r')"
    if [[ "$uid" == "0" ]]; then
      echo -e "${GREEN}  ✓ Root shell active (uid=0). Sending MICOM UART command 0xC2 0x00 0x00...${RESET}"
      echo "    (Note: Switching the USB mux to external Micro-USB will disconnect internal Wi-Fi!)"
      adb -s "$serial" shell "stop; pkill -f com.lge.smartspeaker; stty -F /dev/ttyHSL1 19200 raw -echo; printf '\xf5\xc2\x00\x01\x00\x3c\xfa' > /dev/ttyHSL1" 2>/dev/null || true
      echo -e "${GREEN}  ✓ Command sent. Check your USB port with './scripts/monitor-usb-adb.sh'.${RESET}"
    else
      echo -e "${RED}  ✗ 'adb root' did not grant uid=0 (current uid=${uid:-unknown}). Cannot write to /dev/ttyHSL1.${RESET}"
    fi
  else
    echo ""
    echo "Tip: To switch the hardware USB mux from internal Wi-Fi to the bottom"
    echo "     Micro-USB port (requires root), re-run with:"
    echo "     $0 ${ip} --switch-usb"
  fi
  return 0
}

# 1. If user specified an IP, probe it directly
if [[ -n "$TARGET_IP" ]]; then
  probe_ip "$TARGET_IP"
  exit $?
fi

# 2. Otherwise, check the Factory-Reset / Setup Hotspot gateway (192.168.255.249) first
echo ""
echo "No IP specified — checking Factory-Reset Setup Hotspot (192.168.255.249) first..."
echo "(If your speaker was factory-reset, connect your computer's Wi-Fi to the open"
echo " 'LG_WK7_xxxx.n019' or 'WK7xxxx.n019' hotspot first.)"

if ping -c 1 -W 1 192.168.255.249 >/dev/null 2>&1; then
  if probe_ip "192.168.255.249"; then
    exit 0
  fi
fi

# 3. Scan ARP table / local subnet for reachable devices
echo ""
echo "Scanning local network ARP cache for WK7 speakers..."
CANDIDATES="$(arp -a 2>/dev/null | awk -F'[()]' '{print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -vE '\.255$|^224\.|^239\.' | sort -u || true)"

if [[ -z "$CANDIDATES" ]]; then
  echo -e "${YELLOW}No entries found in ARP table. Please pass the speaker's IP directly:${RESET}"
  echo "  $0 <speaker-ip>"
  exit 1
fi

FOUND=0
for ip in $CANDIDATES; do
  # Quick check on port 8008 (Cast) or 5555 (ADB) before full probe
  if [[ -n "$(check_cast_info "$ip")" ]]; then
    if probe_ip "$ip"; then
      FOUND=1
      break
    fi
  fi
done

if [[ "$FOUND" -eq 0 ]]; then
  echo ""
  echo -e "${YELLOW}No WK7 speaker automatically discovered in ARP cache.${RESET}"
  echo "If you know your speaker's IP (or after connecting to its LG_WK7_xxxx.n019 hotspot), run:"
  echo "  $0 <speaker-ip>"
  exit 1
fi
