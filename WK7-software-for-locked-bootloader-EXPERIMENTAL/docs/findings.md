# Findings: Wi-Fi, Cast, and Bluetooth (BLE GATT) Access on a Locked Retail LG WK7

**Scope:** Live wireless probing (Wi-Fi soft-AP, LAN, Google Cast v2, and BLE GATT) on a **retail bootloader-locked LG WK7** (`user` / `release-keys` build).  
**Related docs:** [`../README.md`](../README.md) · [`../AGENTS.md`](../AGENTS.md) · [`locked.md`](locked.md) · [`unauthenticated-api.md`](unauthenticated-api.md) · [`../../README.md`](../../README.md)

---

## Target Unit & Firmware State

All observations below come from live testing on a single retail WK7 unit before and after a physical factory reset (holding the base `RESET` button):

| Field | Observed Value |
|---|---|
| Device name | `LG-WK7_0447` (before reset) → `LG-WK7_4824` (after reset) |
| Hotspot BSSID / soft-AP | `FA:8F:CA:CC:C2:9E` (`LG-WK7_0447.n019` → `LG-WK7_4824.n019`, ch 6 / 2437 MHz) |
| Wi-Fi station MAC | `00:51:ed:6d:48:04` |
| TLS cert (`8443`, `9000`) | Self-signed, `O=LG Electronics Inc.`, `CN=AB0C936D350A FA8FCACCC29E` |
| System build | `NIT1.190501.001` (May 2019; predates June 2019 `cast-local-authorization-token`) |
| OEM version | `A190521.4fc3f4eQ-175` |
| Cast build revision | `1.36.157053` (`build_version: 157053`) |
| OS / Kernel / Patch | Android Things 0.4.5 / Linux 3.10.49 / 2017-10-05 security patch |
| Platform | Qualcomm APQ8009 (Snapdragon 212), 32-bit ARM, 8 GB eMMC, 44 partitions A/B |

---

## Blocker Matrix (Wireless Access Paths)

| Path | Hardware State | Verified Working | Blocker | Next Step |
|---|---|---|---|---|
| **Wi-Fi ADB (`:5555`)** | Setup AP & LAN | — | ❌ **Connection refused** on `:5555`; all other open ports fail ADB handshake (`offline`) | None over Wi-Fi (`adbd` disabled in retail `user` build) |
| **Setup HTTP/HTTPS API (`:8008` / `:8443`)** | Setup AP & LAN | **Unauthenticated control & provisioning** (`eureka_info`, `scan_wifi`, `scan_results`, `connect_wifi`, `accept_tos`, `forget_wifi`, `reboot now`) | ❌ No shell, no file access; `/setup/reboot` rejects `bootloader`, `recovery`, `edl` (`400`) | Useful for Wi-Fi provisioning / daily Cast audio only |
| **Cast v2 `LAUNCH` (`:8009`)** | Setup AP (`setup_state: 10`) | Plaintext Cast protobuf (`CONNECT`, `GET_STATUS`, `GET_APP_AVAILABILITY`) | ❌ App registry empty (`APP_UNAVAILABLE` / `NOT_FOUND` on `CC1AD845` + 23 app IDs); no public Magellan RCE or AVB bypass | Complete Google Home app setup if testing Cast app availability; still no public RCE/unlock path |
| **BLE GATT (`0xfea0`)** | Setup mode (`setup_state: 10`) | **Unauthenticated GATT read/write** (name, Wi-Fi scans, opt-in, temporary RSA key, Wi-Fi config) | ❌ **Provisioning-only transport** — no ADB toggle, no shell, no debug characteristic; hidden once provisioned | None for root/ADB; alternate provisioning transport only |
| **BLE GATT (`0xfea0`)** | Provisioned (`setup_state: 64`) | — | ❌ **Not discoverable** — BLE advertisement stops once Wi-Fi is configured | Hold base `RESET` button (~5–15 s) to return to setup mode |
| **Physical UART (`TP514`/`TP515`)** | Housing opened | Not yet tested in this probe | ⚠️ Requires disassembly + `1.8V` USB-UART adapter | See [`../../README.md`](../../README.md) & [`../../scripts/pcb-hardware-probe.sh`](../../scripts/pcb-hardware-probe.sh) |

---

## 1. Wi-Fi Access Attempts

### 1.1 Open Setup Soft-AP & Port Scan

When unprovisioned (`setup_state: 10`), the WK7 broadcasts an open setup hotspot (`LG-WK7_<suffix>.n019`, channel 6, gateway `192.168.255.249/29`). Connecting a computer directly requires no password or app.

A full TCP port scan (`1–10000` plus high ports) on `192.168.255.249` (setup AP) and `192.168.50.238` (LAN) found the exact same 7 open ports:

| Port | Service / Observed Behaviour |
|---|---|
| `53` | DNS resolver (setup soft-AP) |
| `8008` | HTTP Cast setup API (unauthenticated) |
| `8009` | Google Cast v2 protobuf protocol |
| `8443` | HTTPS Cast setup API (self-signed LG cert, unauthenticated) |
| `9000` | TLS service (same LG cert; returns TLS alert on raw/HTTP probes) |
| `9741` | TCP service (silent; times out on HTTP and TLS ClientHello probes) |
| `10001` | Google Zone protocol (`_googlezone._tcp`) |

**What does not work:**
- **Port `5555` (Wi-Fi ADB)** returned `Connection refused` in both setup mode and provisioned LAN mode.
- Running `adb connect` against every open port (`8008`, `8009`, `8443`, `9000`, `9741`, `10001`) left every target `offline` (no `adbd` handshake).

### 1.2 Unauthenticated Setup API (`:8008` / `:8443`)

Because `NIT1.190501.001` (May 2019) predates Google's June 2019 `cast-local-authorization-token` enforcement, setup endpoints accept requests without a token or pairing (see [`unauthenticated-api.md`](unauthenticated-api.md) for the full endpoint breakdown).

**Verified working:**
- `GET /setup/eureka_info`, `/setup/scan_results`, `/setup/configured_networks` → `200 OK`
- `POST /setup/accept_tos`, `/setup/scan_wifi` → `200 OK` with empty `{}` JSON
- `POST /setup/connect_wifi` → `200 OK` when passed `bssid`, `signal_level`, `ssid`, `wpa_auth`, `wpa_cipher`, and `enc_passwd` (WPA-PSK encrypted with RSA **PKCS#1 v1.5** using the device's `public_key` from `eureka_info`, then base64-encoded).
- `POST /setup/forget_wifi` (`{"wpa_id": <id>}`) → `200 OK` in setup mode (clears saved networks); **returned `500` when invoked on LAN `192.168.50.238` while provisioned**.
- `POST /setup/reboot` (`{"params":"now"}`) → `200 OK` on LAN `192.168.50.238` and cleanly rebooted the speaker (came back to `setup_state: 64`, `wpa_state: 10`).

**Verified NOT working:**
- **Alternate reboot modes blocked:** On LAN `192.168.50.238`, `POST /setup/reboot` returned **HTTP `400`** for:
  - `{"params":"bootloader"}`
  - `{"params":"recovery"}`
  - `{"params":"edl"}`
- **OTA / debug / reset routes absent (`404`):** `/setup/ota_status`, `/setup/apply_ota`, `/setup/check_ota`, `/setup/reset`, `/setup/factory_reset`, `/setup/supported_app_ids`, `/setup/get_local_authorization_token`, `/setup/get_system_property`, `/setup/bluetooth/status`, `/setup/bluetooth/get_bonded`, `/setup/timezone`, `/setup/night_mode`.
- `/setup/offer` returned `500` on `GET` and `405` on `POST`.
- Note on `eureka_info` capability flags: `device_info.capabilities` reports `"reboot_supported": false` and `"fdr_supported": false`, even though `{"params":"now"}` on `/setup/reboot` still executes.

### 1.3 Wi-Fi Provisioning Behaviour (Software AP vs. Home Router)

We tested provisioning the WK7 via `POST /setup/connect_wifi` against two targets:

1. **Host-controlled Linux `nmcli` / `wpa_supplicant` hotspot (`WK7LAB`, channel 6, `dnsmasq`):**
   - **Worked:** Racing `POST /setup/connect_wifi` followed by `nmcli connection up Hotspot` succeeded. The speaker RSA-decrypted the PSK, passed the WPA2 4-way handshake, and associated at `-22 dBm`.
   - **Failed:** `dnsmasq` never received a `DHCPDISCOVER` from the speaker (`num_obtain_ip` climbed to `17`), even though `dnsmasq` answered a synthetic DHCP test client on the host. Without an IP/internet (`ip_forward` was also `0` initially), the speaker repeatedly disassociated and cleanly reverted to setup mode (`setup_state: 10`) once the hotspot stopped.
2. **Real home router (`horizon`, `d4:5d:64:9f:a5:80`):**
   - **Worked:** The speaker obtained `192.168.50.238`, reported `net.online: true` and `wpa_state: 10`, and advertised `_googlecast._tcp` and `_lg-smart-device._tcp` over mDNS.
   - **Stability caveat:** During early provisioning attempts before full setup stabilized (`num_connected_wifi_not_saved` incrementing, `setup_state: 61`), the unit reverted back to setup mode (`setup_state: 10`) within ~1 minute. Once it reached `setup_state: 64` (`wpa_configured: true`), it stayed on the LAN and persisted across `/setup/reboot`.

### 1.4 Cast v2 Protocol & `contentUrl` RCE Path (`:8009`)

The DEF CON 27 / Black Hat 2019 Chromecast attack chain launches the Cast Default Media Receiver (`CC1AD845`) with an arbitrary `contentUrl` so the device's embedded Chromium fetches and renders an HTML page, then chains a renderer vulnerability (e.g., Magellan SQLite `CVE-2018-20346` / `-20505` / `-20506`) with privilege escalation.

**Verified on the WK7:**
- In setup mode (`192.168.255.249:8009`), plaintext Cast v2 protobuf `CONNECT` and `GET_STATUS` succeeded (`RECEIVER_STATUS` returned master volume `0.533` and `userEq: {}`).
- **Blocked at `LAUNCH`:** `GET_APP_AVAILABILITY` for `["CC1AD845", "233637DE"]` returned `APP_UNAVAILABLE`, and `LAUNCH` attempts against `CC1AD845` plus 23 other known Cast app IDs all returned `LAUNCH_ERROR` with `reason=NOT_FOUND`. The Cast app registry is empty when unprovisioned.
- On the LAN (`192.168.50.238:8009`, while in `setup_state: 61`), port `8009` accepted TCP connections but returned no Cast responses to plaintext probes (and TLS 1.2 handshake timed out before the unit dropped back to setup mode).
- **Why this is not a viable firmware-flashing path:** Even if completing full Google Home app setup populated the Cast app registry, there is **no public Magellan RCE payload**, no public Linux `3.10.49` kernel escalation tailored to this build, and no software AVB bypass to flash signed `boot`/`system`/`vbmeta` partitions.

---

## 2. Bluetooth / BLE GATT Access Attempts

### 2.1 Discoverability & Address Rotation

- **Provisioned state (`setup_state: 64`, `wpa_configured: true`):** The WK7 is **not discoverable** over Bluetooth or BLE scans (`bluetoothctl` / `btmgmt` / `bleak` saw zero advertisements from the speaker). Calling `/setup/reboot` did not re-enable BLE discovery while Wi-Fi remained configured.
- **Factory-reset / setup state (`setup_state: 10`):** Holding the physical `RESET` button on the bottom of the speaker for ~15 seconds reset Wi-Fi and restored BLE advertising immediately:
  - Advertised local name: `LG-WK7_4824`
  - Service UUID: `0000fea0-0000-1000-8000-00805f9b34fb` (Google)
  - Service data (`0xfea0`): `03fa8fcaccc29e6e3031391eff` (`fa8fcaccc29e` = `hotspot_bssid`, `6e303139` = ASCII `n019`)
- **Rotating MAC address:** The speaker uses a resolvable private random BLE address that rotates between scans (observed `49:2A:66:79:C7:48`, then `7B:61:7F:30:6D:51` minutes later). Scripts must scan by local name or `0xfea0` service UUID rather than hardcoding an address.

### 2.2 GATT Enumeration (Unauthenticated)

Connecting via `bleak` succeeded with **no pairing, no bonding, no encryption, and no authentication**.

Three services are exposed:
- `00001800-...` (Generic Access Profile): Device Name (`LG-WK7_4824`), Appearance (`0000`), Central Address Resolution (`01`).
- `00001801-...` (Generic Attribute Profile): Service Changed (`indicate`).
- `0000fea0-...` (Google): **23 characteristics** (16 readable, 7 write-only; 4 have both `read,write`).

#### Verified Readable Characteristics (`0xfea0`)

| Handle | UUID prefix | Props | Observed Value (Decoded) |
|---|---|---|---|
| `41` | `007c6160` | `read` | `0x09` (protocol version `9`) |
| `43` | `017c6160` | `read` | `LG-WK7_4824` (device name) |
| `45` | `037c6160` | `read` | `0x00` |
| `47` | `0c7c6160` | `read` | `0x0a` (`setup_state: 10`) |
| `49` | `0d7c6160` | `read` | *(empty, 0 bytes)* |
| `51` | `127c6160` | `read` | `{"ready_to_apply":false}` |
| `53` | `157c6160` | `read` | 376 B gzip → 1,586 B JSON nearby Wi-Fi scan list (`ap_list`, BSSIDs, SSIDs, RSSI) |
| `55` | `156c6160` | `read,write` | `0x00` |
| `57` | `197c6160` | `read` | 512 B (truncated gzip; temporary RSA public key per published Google Home BLE setup analysis) |
| `59` | `196c6160` | `read,write` | `0x00` |
| `61` | `1a7c6160` | `read` | 512 B (truncated gzip) |
| `63` | `1a6c6160` | `read,write` | `0x00` |
| `65` | `1b7c6160` | `read` | 512 B (truncated gzip) |
| `67` | `1b6c6160` | `read,write` | `0x00` |
| `69` | `1c7c6160` | `read` | 45 B gzip → 25 B JSON `{"opt_in":{"stats":true}}` |
| `71` | `1c6c6160` | `read,write` | `0x00` |
| `87` | `0128fe40` | `read,write` | `GB` (country code) |

*(Note: Characteristics `57`, `61`, and `65` start with gzip header `1f 8b 08 ...` and exceed the 512-byte single ATT read cap; reading them in full requires larger MTU / ATT long-read handling.)*

#### Write-Only Provisioning Characteristics (`0xfea0`)

| Handle | UUID prefix | Props | Role |
|---|---|---|---|
| `73` | `0028fe40` | `write` | Provisioning command channel |
| `75` | `0228fe40` | `write` | Provisioning command channel |
| `77` | `0328fe40` | `write` | Wi-Fi configuration write (RSA-encrypted PSK) |
| `79` | `0428fe40` | `write` | Provisioning command channel |
| `81` | `0528fe40` | `write` | Provisioning command channel |
| `83` | `137c6160` | `write` | Provisioning command channel |
| `85` | `147c6160` | `write` | Provisioning command channel |

*(We did not fuzz the write-only provisioning channels blind.)*

### 2.3 Conclusion on BLE

BLE GATT on `0xfea0` is strictly an **alternative provisioning transport** mirroring the HTTP/HTTPS `/setup/*` API. It exposes no ADB toggle, no debug shell, no Fastboot/EDL trigger, and no memory/file read primitive.

---

## 3. Overall Takeaway for Locked Retail Units

1. **What works wirelessly:** Unauthenticated device recon, Wi-Fi provisioning (`/setup/connect_wifi` or BLE `0xfea0`), and normal reboot (`{"params":"now"}`). This is enough to recover an unprovisioned/bricked-by-cloud retail unit as a local Google Cast audio target without disassembly.
2. **What does NOT work wirelessly:** Wi-Fi ADB (`:5555` refused), Cast `LAUNCH` media delivery (`NOT_FOUND` on empty app registry), `/setup/reboot` into `bootloader`/`recovery`/`edl` (`400`), and BLE debug/ADB access.
3. **Only remaining local root/Fastboot vector:** Opening the housing and probing the hardware `1.8V` UART console (`TP514`/`TP515`) and `3.3V` MICOM USB switch (`R708`) with [`../../scripts/pcb-hardware-probe.sh`](../../scripts/pcb-hardware-probe.sh) (see [`../../README.md`](../../README.md)). Whether the retail `user` kernel drops an interactive root shell or log-only output on `ttyHSL0` remains to be confirmed on hardware.
