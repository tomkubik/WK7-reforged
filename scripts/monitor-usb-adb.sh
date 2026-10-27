#!/usr/bin/env bash
# monitor-usb-adb.sh — Live USB, ADB, and Fastboot monitor for LG WK7 speakers.
# Works on macOS and Linux. Safe and read-only.
#
# Usage:
#   ./scripts/monitor-usb-adb.sh

set -u

BOLD="\033[1m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RED="\033[1;31m"
RESET="\033[0m"

echo -e "${BOLD}======================================================================${RESET}"
echo -e "${BOLD} LG WK7 — Live USB / ADB / Fastboot Connection Monitor${RESET}"
echo -e "${BOLD}======================================================================${RESET}"
echo ""
echo -e "${CYAN}Connection Notes:${RESET}"
echo "  - Prototype / developer (EV/DV) & Slot B units enumerate directly on"
echo "    Micro-USB at power-on (use a rear motherboard USB port, then plug 19V DC)."
echo "  - Unopened retail (MP) units route USB to internal Wi-Fi and disable"
echo "    android0/enable once Android boots. Check Wi-Fi first with:"
echo "      ./scripts/connect-wifi-adb.sh"
echo "  - Opened retail PCBs halted in Fastboot/EDL: switch IC502 over UART with:"
echo "      ./scripts/pcb-hardware-probe.sh --switch-usb"
echo ""
echo "Watching USB bus, 'adb devices', and 'fastboot devices' (Ctrl+C to stop)..."
echo "----------------------------------------------------------------------"

check_usb_bus() {
  if command -v lsusb >/dev/null 2>&1; then
    lsusb 2>/dev/null | grep -iE "05c6:|18d1:|1004:" || true
  elif command -v ioreg >/dev/null 2>&1; then
    # macOS: check IOUSB plane for Qualcomm (0x05c6 = 1478), Google (0x18d1 = 6353), LG (0x1004 = 4100)
    ioreg -p IOUSB -w0 -l 2>/dev/null | awk '
      /\"idVendor\" = (1478|6353|4100)$/ { v=$NF }
      /\"idProduct\" = / { if (v) { print "macOS USB device detected: idVendor=" v " idProduct=" $NF; v="" } }
    ' || true
  fi
}

probe_adb_device() {
  local serial="$1"
  echo ""
  echo -e "${GREEN}✓ ADB Device Detected:${RESET} ${BOLD}${serial}${RESET}"
  echo "  Waiting for device to finish initializing..."
  adb -s "$serial" wait-for-device >/dev/null 2>&1 || true

  local model device boot_state verified_state build_type debuggable
  model="$(adb -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
  device="$(adb -s "$serial" shell getprop ro.product.device 2>/dev/null | tr -d '\r')"
  boot_state="$(adb -s "$serial" shell getprop ro.boot.vbmeta.device_state 2>/dev/null | tr -d '\r')"
  verified_state="$(adb -s "$serial" shell getprop ro.boot.verifiedbootstate 2>/dev/null | tr -d '\r')"
  build_type="$(adb -s "$serial" shell getprop ro.build.type 2>/dev/null | tr -d '\r')"
  debuggable="$(adb -s "$serial" shell getprop ro.debuggable 2>/dev/null | tr -d '\r')"

  echo "----------------------------------------------------------------------"
  echo -e "  Model:                        ${BOLD}${model:-unknown}${RESET} (${device:-unknown})"
  echo -e "  ro.boot.vbmeta.device_state:  ${BOLD}${boot_state:-unknown}${RESET}"
  echo -e "  ro.boot.verifiedbootstate:    ${BOLD}${verified_state:-unknown}${RESET}"
  echo -e "  ro.build.type:                ${BOLD}${build_type:-unknown}${RESET} (ro.debuggable=${debuggable:-?})"
  echo "----------------------------------------------------------------------"

  if [[ "$model" != *WK7* && -n "$model" ]]; then
    echo -e "${YELLOW}⚠ Warning: Connected ADB device model is '${model}', not an LG WK7.${RESET}"
    return 0
  fi

  if [[ "$boot_state" == "unlocked" || "$verified_state" == "orange" ]]; then
    echo -e "${GREEN}>>> RESULT: UNLOCKED BOOTLOADER!${RESET}"
    echo "    Use the main folder: WK7-software-for-unlocked-bootloader/"
  else
    echo -e "${YELLOW}>>> RESULT: LOCKED BOOTLOADER (${verified_state:-locked})${RESET}"
    echo "    Use the experimental folder: WK7-software-for-locked-bootloader-EXPERIMENTAL/"
  fi
}

probe_fastboot_device() {
  local serial="$1"
  echo ""
  echo -e "${GREEN}✓ Fastboot Device Detected:${RESET} ${BOLD}${serial}${RESET}"
  echo "----------------------------------------------------------------------"
  for var in product unlocked secure current-slot version-bootloader; do
    local val
    val="$(fastboot -s "$serial" getvar "$var" 2>&1 | awk -F': ' '/^'"$var"':/ {print $2}' | tr -d '\r')"
    printf "  %-22s %s\n" "${var}:" "${val:-unknown}"
  done
  echo ""
  echo "  --- oem device-info ---"
  fastboot -s "$serial" oem device-info 2>&1 | tr -d '\r' | sed 's/^/  /' || true
  echo ""
  echo "  --- at-vboot-state & unlock ability ---"
  fastboot -s "$serial" flashing get_unlock_ability 2>&1 | tr -d '\r' | sed 's/^/  /' || true
  fastboot -s "$serial" getvar at-vboot-state 2>&1 | tr -d '\r' | sed 's/^/  /' || true
  echo "----------------------------------------------------------------------"
}

LAST_USB=""
TICKS=0

while true; do
  # 1. Check raw USB bus for Qualcomm / Google / LG IDs
  USB_NOW="$(check_usb_bus)"
  if [[ -n "$USB_NOW" && "$USB_NOW" != "$LAST_USB" ]]; then
    echo ""
    echo -e "${GREEN}✓ Raw USB Bus Enumeration Detected:${RESET}"
    echo "$USB_NOW" | sed 's/^/  /'
    if echo "$USB_NOW" | grep -qiE "9008|36872"; then
      echo -e "${YELLOW}  -> Device is in Qualcomm EDL 9008 mode (05c6:9008).${RESET}"
    fi
    LAST_USB="$USB_NOW"
  fi

  # 2. Check ADB devices (exclude TCP/IP ':5555' connections when monitoring USB, or show any ready device)
  if command -v adb >/dev/null 2>&1; then
    ADB_LINE="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1; exit}')"
    if [[ -n "$ADB_LINE" ]]; then
      probe_adb_device "$ADB_LINE"
      exit 0
    fi
    ADB_UNAUTH="$(adb devices 2>/dev/null | awk 'NR>1 && ($2=="unauthorized" || $2=="offline") {print $1 " (" $2 ")"; exit}')"
    if [[ -n "$ADB_UNAUTH" ]]; then
      echo ""
      echo -e "${YELLOW}⚠ ADB device seen as ${ADB_UNAUTH} — waiting for ready state...${RESET}"
    fi
  fi

  # 3. Check Fastboot devices
  if command -v fastboot >/dev/null 2>&1; then
    FB_LINE="$(fastboot devices 2>/dev/null | awk 'NF>=2 {print $1; exit}')"
    if [[ -n "$FB_LINE" ]]; then
      probe_fastboot_device "$FB_LINE"
      exit 0
    fi
  fi

  TICKS=$((TICKS + 1))
  printf "\r  [%03ds] Waiting for USB / ADB / Fastboot connection... " "$TICKS"
  sleep 1
done
