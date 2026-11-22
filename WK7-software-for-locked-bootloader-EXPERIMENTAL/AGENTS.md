# AGENTS.md — locked-bootloader toolkit

Scope: this file applies to `WK7-software-for-locked-bootloader-EXPERIMENTAL/` only. For the
main (unlocked) project see `../WK7-software-for-unlocked-bootloader/wk7-build/AGENTS.md`.

## What this is

Diagnostic and flashing tooling for WK7 units whose bootloader is **locked**.
Parallel to the main project; nothing in the unlocked path is modified or
duplicated here.

## Rules you must not break

1. **Never claim a locked-device result that was not observed.** The single most
   important rule here. This folder's value is that it is honest about its own
   uncertainty; a confident-sounding claim about an untested device is worse
   than no claim.
2. **Never write to a firmware partition from this folder's tooling** except via
   `02_restore.sh` or `03_flash_adb_root.sh`, both of which require the literal
   word `YES`. `install-locked.sh` writes only to `/data` and must stay that way.
3. **Never remove the device-identity check.** Another device on the network
   will answer adb on 5555 — a real Google Home did during testing. Verify
   `ro.product.model` before writing.
4. **Do not touch early-boot partitions.** `sbl1_*`, `tz_*`, `rpm_*` are
   effectively unrecoverable if written wrongly on a locked device.
5. **Back up before writing.** `01_backup.sh` first, always.

## Verified facts

From the one unlocked unit:

- Front-panel USB headers do **not** enumerate the device; the rear
  motherboard port does, instantly. Zero USB events were logged on the front
  panel — not even a failed handshake.
- USB IDs: ADB `05c6:901d`, fastboot `18d1:d00d`, EDL `05c6:9008`
- ADB is compiled into the boot default (`ro.sys.usb.default.config=diag,adb`),
  not exposed through a Settings toggle. Stock `user` builds ship with ADB
  disabled by default; this build does not.
- `ro.build.type=userdebug`, `ro.build.tags=test-keys`, `ro.debuggable=1`
- `ro.boot.verifiedbootstate=orange`, `ro.boot.vbmeta.device_state=unlocked`
- `androidboot.veritymode=disabled`, `androidboot.selinux=permissive`
- eMMC at `7824900.sdhci`; by-name dir
  `/dev/block/platform/soc.0/7824900.sdhci/by-name`
- 44 partitions, A/B
- `console=ttyHSL0,115200,n8` — a UART console exists but needs the housing open

From a **locked retail (`MP`) unit** (`LG-WK7_0447` / `LG-WK7_4824`, `NIT1.190501.001`, 2026-11 — see `docs/findings.md` and `docs/unauthenticated-api.md`):

- Wi-Fi ADB (`:5555`) is **refused** in both setup-AP (`192.168.255.249`) and LAN modes; all other open ports (`53`, `8008`, `8009`, `8443`, `9000`, `9741`, `10001`) fail the ADB handshake (`offline`).
- The local Cast/setup API (`:8008` / `:8443`, May 2019 build, pre-`cast-local-authorization-token`) is **unauthenticated**: `eureka_info`, `scan_wifi`, `scan_results`, `accept_tos`, `connect_wifi` (RSA PKCS#1 v1.5 encrypted PSK), `forget_wifi` (in setup mode), and `reboot` (`{"params":"now"}`) work without a token.
- `/setup/reboot` rejects `bootloader`, `recovery`, and `edl` with HTTP `400`.
- Cast v2 `:8009` `GET_APP_AVAILABILITY` returns `APP_UNAVAILABLE` and `LAUNCH` returns `NOT_FOUND` on unprovisioned units (`CC1AD845` + 23 other IDs).
- BLE GATT (`0000fea0-...`) is only advertised in setup mode (`setup_state: 10`, rotating random MAC), requires no pairing/auth, mirrors Wi-Fi provisioning (including gzipped scan results and `197c6160` RSA key / `0328fe40` Wi-Fi config), and exposes **no** ADB or debug toggle.

## State: what works, what does not

WORKS:
- On an unlocked/`userdebug` unit: device probing, partition backup/restore, `dd`-based flashing via an adb root shell, fastboot inspection, escalation triage, the `/data` installer.
- On a locked retail unit (wireless, verified 2026-11 — see `docs/findings.md`): unauthenticated device recon, Wi-Fi provisioning (`/setup/connect_wifi` or BLE `0xfea0`), and normal reboot (`{"params":"now"}`).

DOES NOT WORK / UNVERIFIED:
- Wi-Fi ADB (`:5555`), BLE debug/ADB, Cast `LAUNCH` RCE (`NOT_FOUND` on empty app registry), and `/setup/reboot` to `bootloader`/`recovery`/`edl` (`400`) on locked retail units (`docs/findings.md`).
- Unlocking a locked unit. The Android Things Console that issued LG's unlock credentials was permanently deleted on 2022-01-05; retail `device_info` is RPMB-backed with `avb_unlock_disabled=1`.
- EDL flashing. Requires an LG-signed SDM212 firehose loader; none included and one cannot be synthesised.
- Kernel exploit. Intentionally not shipped.
- Auto-start at power-on while locked. Structurally impossible.
- Interactive root shell on `1.8V` UART (`TP514`/`TP515`) on retail `user` builds: unverified on physical hardware (requires opening the housing).

## Conventions

- Bash for shell tooling; `source lib/common.sh` for shared state
- Device constants live only in `lib/common.sh`
- Partition sizes in the `PARTITIONS` table must match the verified table
- Destructive scripts warn, then require the literal word `YES`
- Comments explain *why*. Note the date when a value came from probing hardware
- `|| true` on command substitutions that may legitimately return non-zero;
  under `set -e` they will otherwise abort the script silently

## Testing

Safe and read-only:

```bash
./install-locked.sh <ip> --probe
./00_probe.sh
./exploits/00_triage.sh
python3 exploits/02_cve_scout.py
```

Do not exercise `02_restore.sh`, `03_flash_adb_root.sh` or
`05_edl_firehose.sh` without an existing backup.

## Tone

The documentation opens by stating what is untested. Keep it that way. Readers
here own locked consumer hardware with no vendor support; accurate expectations
are more useful than encouragement that papers over dead ends.
