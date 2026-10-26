# Changelog

## v1.5 (2026-10-25)

* **Retail (`MP`) vs. Prototype (`DV`) USB Mux Root-Cause Analysis ([Issue #4](https://github.com/tomkubik/WK7-reforged/issues/4))**:
  - Disassembled the onboard Renesas RL78 MICOM firmware (`M17111305_DV_USB_Mode.hex`) and documented why retail (`MP`/`PV`) speakers keep the bottom `"SERVICE ONLY"` Micro-USB port disconnected at boot (routing the single Qualcomm APQ8009 USB controller to the internal Wi-Fi/BT hub instead).
  - Documented the 3 ordered connection methods for retail speakers:
    1. **Physical `Mic Mute` button toggle (`P2.7`, routine `0x5335`)** after boot *(no new equipment)*.
    2. **ADB over Wi-Fi (`TCP:5555`)** via home LAN or the factory-reset Setup Hotspot (`192.168.255.249` on `LG_WK7_xxxx.n019`), plus software USB mux switching via MICOM UART command `0xC2 0x00 0x00` *(no new equipment)*.
    3. **Micro-USB Pin 4 (`ID` / `ANI5`) sense (`0x9C03`) & recessed connector depth** using an LG Factory Service cable / 5-pin OTG adapter and long-tip plug *(`[Requires new cable]`)*.
* **New Diagnostic & Monitoring Helper Scripts (`scripts/`)**:
  - Added [`scripts/monitor-usb-adb.sh`](scripts/monitor-usb-adb.sh): Live cross-platform (macOS + Linux) USB bus, ADB, and Fastboot monitor that auto-detects the speaker and queries bootloader unlock state.
  - Added [`scripts/connect-wifi-adb.sh`](scripts/connect-wifi-adb.sh): Auto-discovers the speaker on the Setup Hotspot (`192.168.255.249`) or local LAN (`:8008`), probes Wi-Fi ADB (`:5555`) with `ro.product.model` verification, diagnoses locked `user` builds, and supports `--switch-usb` to flip the MICOM USB switch in software.
* **Expanded Documentation**:
  - Added the **Hardware Connection & Required Cables** reference table in `README.md`.
  - Added the complete high-level installation walkthrough and technical links for **Unlocked-Bootloader Units**.
  - Ported comprehensive technical pointers, `/data` architecture notes, and script references for **Locked-Bootloader Units (Experimental)** into the main `README.md`.
