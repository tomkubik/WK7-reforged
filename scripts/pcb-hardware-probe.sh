#!/usr/bin/env bash
# pcb-hardware-probe.sh — Hardware UART & Fastboot test helper for opened LG WK7 PCBs (EAX67850001).
# Works on macOS and Linux using Python 3 standard library (termios/select — no pyserial needed).
#
# Modes:
#   ./scripts/pcb-hardware-probe.sh --console         # Read 1.8V SoC UART boot log (TP514 / TP515, 115200 8N1)
#   ./scripts/pcb-hardware-probe.sh --switch-usb      # Send 3.3V MICOM 0xC2 USB-switch frame on R708 & watch USB
#   ./scripts/pcb-hardware-probe.sh --fastboot-probe  # Read-only probe of Fastboot (18d1:d00d) lock/RPMB state
#   ./scripts/pcb-hardware-probe.sh --fastboot-probe --try-unlock  # Attempt Fastboot unlock commands (erases /data)

set -u

BOLD="\033[1m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RED="\033[1;31m"
RESET="\033[0m"

MODE=""
SERIAL_PORT=""
SEND_ONCE=0
ROUTE_STATE=0   # 0 = external Micro-USB socket, 1 = internal Wi-Fi/BT hub
TRY_UNLOCK=0

usage() {
  cat <<EOF
Usage: $0 <mode> [options]

Hardware test helper for an opened LG WK7 retail mainboard (EAX67850001_VER1.7 PV).
Works on both macOS (/dev/cu.usbserial-*) and Linux (/dev/ttyUSB*).

Modes:
  --console          Open 115200 8N1 serial reader for APQ8009 ttyHSL0 boot logs.
                     [!] STRICTLY 1.8V LOGIC: GND -> G101 shield, RX -> TP514 or TP515.
  --switch-usb       Repeatedly send the 7-byte MICOM USB-switch command (115200 8N1)
                     every 0.5s while watching USB for Fastboot (18d1:d00d) or EDL (05c6:9008).
                     [!] 3.3V LOGIC: GND -> board ground, TX -> R708 (top-left of IC700 100GEA).
  --fastboot-probe   Query Fastboot variables ('getvar all', 'oem device-info', unlock ability).
                     Read-only unless combined with --try-unlock.

Options:
  --port <dev>       Serial device path (auto-detected if omitted, e.g. /dev/ttyUSB0 or /dev/cu.usbserial-*)
  --once             With --switch-usb: send the 7-byte frame once and exit (do not loop/poll USB)
  --internal-wifi    With --switch-usb: send state 0x01 (route USB back to internal Wi-Fi/BT hub)
  --try-unlock       With --fastboot-probe: test 'oem at-unlock-vboot default_credential' & 'oem unlock'
                     (WARNING: unlocking erases /data if accepted by bootloader)
  -h, --help         Show this help and the 3-step PCB connection sequence

Recommended 3-Step Sequence on an Opened Retail PCB:
  1. (Optional) Verify boot state over 1.8V UART on TP514 / TP515:
       $0 --console
  2. Halt aboot in Fastboot mode at cold power-on (no race condition once in Fastboot):
       - Back PCB (bottom-left behind Micro-USB G102): hold 'KEY' shorted to 'GND' while
         plugging in 19V power (~2s), then release.
       - Fallback (Front PCB, above SKhynix eMMC IC400): plug in 19V power, wait ~1s for
         aboot to load, then briefly short 'TP401' (or R400) to 'GND' for ~1s.
  3. Plug Micro-USB cable into PC, set UART adapter to 3.3V, run:
       $0 --switch-usb
     and touch UART TX probe tip to resistor R708 (top-left of IC700 '100GEA').
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --console)        MODE="console"; shift ;;
    --switch-usb)     MODE="switch-usb"; shift ;;
    --fastboot-probe) MODE="fastboot-probe"; shift ;;
    --port)
      [[ $# -ge 2 ]] || { echo "Error: --port requires a device path"; exit 1; }
      SERIAL_PORT="$2"; shift 2 ;;
    --once)           SEND_ONCE=1; shift ;;
    --internal-wifi)  ROUTE_STATE=1; shift ;;
    --try-unlock)     TRY_UNLOCK=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)
      echo -e "${RED}Unknown option: $1${RESET}"
      usage
      exit 1 ;;
  esac
done

if [[ -z "$MODE" ]]; then
  usage
  exit 0
fi

require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo -e "${RED}Error: python3 is required for cross-platform serial I/O (macOS/Linux).${RESET}"
    exit 1
  fi
}

detect_serial_port() {
  if [[ -n "$SERIAL_PORT" ]]; then
    if [[ ! -e "$SERIAL_PORT" ]]; then
      echo -e "${RED}Error: Serial port '${SERIAL_PORT}' does not exist.${RESET}" >&2
      exit 1
    fi
    echo "$SERIAL_PORT"
    return 0
  fi

  local candidates=()
  local dev
  for dev in /dev/ttyUSB* /dev/ttyACM* /dev/cu.usbserial* /dev/cu.wchusbserial* /dev/cu.SLAB_USBtoUART* /dev/cu.usbmodem*; do
    [[ -e "$dev" ]] && candidates+=("$dev")
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    echo -e "${RED}Error: No USB-UART serial adapter detected in /dev/.${RESET}" >&2
    echo "Plug in your USB-to-TTL adapter or pass '--port /dev/...' explicitly." >&2
    exit 1
  elif [[ ${#candidates[@]} -eq 1 ]]; then
    echo "${candidates[0]}"
    return 0
  else
    echo -e "${YELLOW}Multiple serial ports detected:${RESET}" >&2
    local c
    for c in "${candidates[@]}"; do
      echo "  $c" >&2
    done
    echo -e "${RED}Please specify one with: --port <device>${RESET}" >&2
    exit 1
  fi
}

check_usb_bus() {
  if command -v lsusb >/dev/null 2>&1; then
    lsusb 2>/dev/null | grep -iE "05c6:|18d1:|1004:" || true
  elif command -v ioreg >/dev/null 2>&1; then
    ioreg -p IOUSB -w0 -l 2>/dev/null | awk '
      /\"idVendor\" = (1478|6353|4100)$/ { v=$NF }
      /\"idProduct\" = / {
        if (v) {
          printf "macOS USB: idVendor=0x%04x idProduct=0x%04x\n", v, $NF
          v=""
        }
      }
    ' || true
  fi
}

run_fastboot_probe() {
  if ! command -v fastboot >/dev/null 2>&1; then
    echo -e "${RED}Error: 'fastboot' is not installed or not in PATH.${RESET}"
    echo "Install Android Platform Tools (brew install android-platform-tools / apt install fastboot)."
    exit 1
  fi

  echo -e "${BOLD}======================================================================${RESET}"
  echo -e "${BOLD} LG WK7 — Fastboot Lock & RPMB State Probe${RESET}"
  echo -e "${BOLD}======================================================================${RESET}"

  local fb_dev
  fb_dev="$(fastboot devices 2>/dev/null | awk 'NF>=2 {print $1; exit}')"
  if [[ -z "$fb_dev" ]]; then
    echo "Waiting for Fastboot device (18d1:d00d) on USB (Ctrl+C to cancel)..."
    while [[ -z "$fb_dev" ]]; do
      sleep 1
      fb_dev="$(fastboot devices 2>/dev/null | awk 'NF>=2 {print $1; exit}')"
    done
  fi

  local ts logfile
  ts="$(date +%Y%m%d-%H%M%S)"
  logfile="/tmp/wk7-fastboot-probe-${ts}.log"

  echo -e "${GREEN}✓ Fastboot device connected:${RESET} ${BOLD}${fb_dev}${RESET}"
  echo "  Saving raw output to: ${logfile}"
  echo "----------------------------------------------------------------------"

  {
    echo "=== fastboot devices ==="
    fastboot devices 2>&1
    echo ""
    echo "=== fastboot getvar all ==="
    fastboot -s "$fb_dev" getvar all 2>&1
    echo ""
    echo "=== fastboot oem device-info ==="
    fastboot -s "$fb_dev" oem device-info 2>&1
    echo ""
    echo "=== fastboot flashing get_unlock_ability ==="
    fastboot -s "$fb_dev" flashing get_unlock_ability 2>&1
    echo ""
    echo "=== fastboot getvar at-vboot-state ==="
    fastboot -s "$fb_dev" getvar at-vboot-state 2>&1
  } | tee "$logfile"

  echo "----------------------------------------------------------------------"
  if grep -qiE "Device unlocked:[[:space:]]*true|unlocked:[[:space:]]*yes" "$logfile"; then
    echo -e "${GREEN}>>> STATUS: Bootloader reports UNLOCKED.${RESET}"
  elif grep -qiE "avb-unlock-disabled:[[:space:]]*(1|true|yes)" "$logfile"; then
    echo -e "${YELLOW}>>> STATUS: Bootloader is LOCKED and reports 'avb-unlock-disabled' set.${RESET}"
    echo "    On Secure Boot retail units, aboot stores device_info in RPMB with"
    echo "    avb_unlock_disabled=1, which blocks Fastboot unlock commands."
  else
    echo -e "${CYAN}>>> STATUS: Bootloader is currently LOCKED (check log above for avb-unlock-disabled).${RESET}"
  fi

  if [[ "$TRY_UNLOCK" -eq 1 ]]; then
    echo ""
    echo -e "${YELLOW}WARNING: Attempting Fastboot unlock commands.${RESET}"
    echo "If accepted by the bootloader, unlocking erases /data (factory reset) and reboots."
    printf "Type UNLOCK to proceed (anything else cancels): "
    local confirm=""
    read -r confirm
    if [[ "$confirm" != "UNLOCK" ]]; then
      echo "Cancelled."
      exit 0
    fi

    echo ""
    echo -e "${CYAN}[1/3] Testing: fastboot oem at-unlock-vboot default_credential${RESET}"
    fastboot -s "$fb_dev" oem at-unlock-vboot default_credential 2>&1 | tee -a "$logfile" || true

    # Check if device already rebooted after at-unlock-vboot
    sleep 2
    if fastboot devices 2>/dev/null | grep -q "$fb_dev"; then
      echo ""
      echo -e "${CYAN}[2/3] Testing: fastboot oem unlock${RESET}"
      fastboot -s "$fb_dev" oem unlock 2>&1 | tee -a "$logfile" || true
      echo ""
      echo -e "${CYAN}[3/3] Testing: fastboot oem unlock-go${RESET}"
      fastboot -s "$fb_dev" oem unlock-go 2>&1 | tee -a "$logfile" || true
    fi
    echo ""
    echo "Unlock test output appended to: ${logfile}"
  else
    echo ""
    echo "Read-only probe complete. To test the unlock commands in aboot, re-run with:"
    echo "  $0 --fastboot-probe --try-unlock"
  fi
}

run_console() {
  require_python3
  local port
  port="$(detect_serial_port)"
  local ts logfile
  ts="$(date +%Y%m%d-%H%M%S)"
  logfile="/tmp/wk7-soc-console-${ts}.log"

  echo -e "${BOLD}======================================================================${RESET}"
  echo -e "${BOLD} LG WK7 — APQ8009 SoC UART Console Reader (ttyHSL0 @ 115200 8N1)${RESET}"
  echo -e "${BOLD}======================================================================${RESET}"
  echo -e "${RED}  [!] VOLTAGE WARNING: Set your USB-UART adapter strictly to 1.8V logic.${RESET}"
  echo "      Do NOT connect 3.3V TX to APQ8009 test pads."
  echo "  Wiring (Front PCB, above IC300 APQ8009, right of P_HOLD / R208):"
  echo "    - Adapter GND -> Micro-USB metal shield (G101)"
  echo "    - Adapter RX  -> TP514 or TP515 (leave Adapter TX disconnected)"
  echo "  Serial Port: ${port}"
  echo "  Log File:    ${logfile}"
  echo "----------------------------------------------------------------------"
  echo "Listening at 115200 8N1 (Ctrl+C to stop)..."

  python3 - "$port" "$logfile" <<'PYEOF'
import os, select, sys, termios, time

port, logfile = sys.argv[1], sys.argv[2]
fd = os.open(port, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
attrs = termios.tcgetattr(fd)
attrs[0] = 0
attrs[1] = 0
attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
attrs[3] = 0
attrs[4] = termios.B115200
attrs[5] = termios.B115200
attrs[6][termios.VMIN] = 1
attrs[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, attrs)
termios.tcflush(fd, termios.TCIFLUSH)

with open(logfile, "ab", buffering=0) as logf:
    try:
        while True:
            r, _, _ = select.select([fd], [], [], 0.5)
            if r:
                chunk = os.read(fd, 1024)
                if not chunk:
                    break
                logf.write(chunk)
                sys.stdout.write(chunk.decode("utf-8", errors="replace"))
                sys.stdout.flush()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        os.close(fd)
PYEOF
}

send_micom_frame_once() {
  local port="$1"
  local state="$2"
  python3 - "$port" "$state" <<'PYEOF'
import os, sys, termios, time

port = sys.argv[1]
state = int(sys.argv[2])
tid = 0x01
cmd1, cmd2, length = 0xC2, 0x00, 0x01
checksum = (0xE5 + tid + cmd1 + cmd2 + length + state) & 0xFF
frame = bytes([0xE5, tid, cmd1, cmd2, checksum, length, state])

fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
try:
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    os.write(fd, frame)
    termios.tcdrain(fd)
    time.sleep(0.02)
finally:
    os.close(fd)
PYEOF
}

run_switch_usb() {
  require_python3
  local port
  port="$(detect_serial_port)"

  local target_desc="External Micro-USB socket (state=0x00, frame: E5 01 C2 00 A9 01 00)"
  if [[ "$ROUTE_STATE" -eq 1 ]]; then
    target_desc="Internal Wi-Fi/BT hub (state=0x01, frame: E5 01 C2 00 AA 01 01)"
  fi

  echo -e "${BOLD}======================================================================${RESET}"
  echo -e "${BOLD} LG WK7 — MICOM (IC700) Hardware USB Switch Sender (115200 8N1)${RESET}"
  echo -e "${BOLD}======================================================================${RESET}"
  echo "  Serial Port: ${port} (set adapter to 3.3V logic)"
  echo "  Target Mux:  ${target_desc}"
  echo "  Wiring (Front PCB, IC700 labeled '100GEA'):"
  echo "    - Adapter GND -> Board ground / Micro-USB shield"
  echo "    - Adapter TX  -> Resistor R708 (or R752) at top-left of IC700 (Pin 51 RxD1)"
  echo "    - Also plug a Micro-USB data cable from the speaker to your PC."
  echo "  Note: Halt the board in Fastboot (or EDL) first; once retail Android boots,"
  echo "        android0/enable=0 disables the SoC USB D+ pull-up."
  echo "----------------------------------------------------------------------"

  if [[ "$SEND_ONCE" -eq 1 || "$ROUTE_STATE" -eq 1 ]]; then
    send_micom_frame_once "$port" "$ROUTE_STATE"
    echo -e "${GREEN}✓ Sent 7-byte MICOM frame on ${port}.${RESET}"
    exit 0
  fi

  echo "Sending 7-byte switch frame every 0.5s while watching USB bus..."
  echo "Touch your UART TX probe needle to R708 now (Ctrl+C to stop)."
  echo ""

  local count=0
  while true; do
    send_micom_frame_once "$port" 0
    count=$((count + 1))

    # Check Fastboot first
    if command -v fastboot >/dev/null 2>&1; then
      local fb_dev
      fb_dev="$(fastboot devices 2>/dev/null | awk 'NF>=2 {print $1; exit}')"
      if [[ -n "$fb_dev" ]]; then
        echo ""
        echo -e "${GREEN}✓ Fastboot device detected (${fb_dev}) after ${count} frame(s)!${RESET}"
        run_fastboot_probe
        exit 0
      fi
    fi

    # Check raw USB bus (EDL 9008 or ADB 901d)
    local usb_now
    usb_now="$(check_usb_bus)"
    if [[ -n "$usb_now" ]]; then
      echo ""
      echo -e "${GREEN}✓ USB device enumerated on host bus after ${count} frame(s):${RESET}"
      echo "$usb_now" | sed 's/^/  /'
      if echo "$usb_now" | grep -qiE "9008|0x9008"; then
        echo -e "${YELLOW}  -> Device is in Qualcomm EDL 9008 mode (05c6:9008).${RESET}"
        echo "     (Note: KEY->GND or t=0 eMMC short entered EDL instead of Fastboot;"
        echo "      to enter Fastboot 18d1:d00d instead, wait ~1s after power-on before"
        echo "      briefly shorting TP401/R400 to GND.)"
      elif echo "$usb_now" | grep -qiE "d00d|0xd00d"; then
        echo -e "${GREEN}  -> Device enumerated as Fastboot (18d1:d00d). Running probe...${RESET}"
        run_fastboot_probe
      fi
      exit 0
    fi

    printf "\r  [Frame #%03d] Transmitting E5 01 C2 00 A9 01 00 on %s — waiting for USB... " "$count" "$port"
    sleep 0.5
  done
}

case "$MODE" in
  console)        run_console ;;
  switch-usb)     run_switch_usb ;;
  fastboot-probe) run_fastboot_probe ;;
esac
