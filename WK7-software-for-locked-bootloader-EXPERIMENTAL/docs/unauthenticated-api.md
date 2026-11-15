# Finding: Unauthenticated Local Control API on the LG WK7

Security finding from live testing of a stock LG WK7 ThinQ smart speaker.

- Testing date: 2026-11 (probe sequence spanning the LG WK7 work session)
- Device: LG WK7 (`LG-WK7_0447`), Google Cast / Android Things home speaker
- SoC: Qualcomm Snapdragon 212 (APQ8009), 4x Cortex-A7, 32-bit, ~700 MB usable RAM
- Storage: 8 GB SK Hynix eMMC, 44 partitions, A/B slots
- OS: Android Things 0.4.5 on Linux 3.10.49
- Build: `NIT1.190501.001` / `oem_version A190521.4fc3f4eQ-175` / cast 1.36.157053
- Security patch level: October 2017
- Device id / mDNS: `LG-WK7-ThinQ-Speaker-5b769b8e...`, eureka model `BA789`, `_googlecast._tcp`

## Summary

The WK7 exposes a **completely unauthenticated HTTP(S) control API**. Any
network peer that can reach the device can read its WiFi state, trigger WiFi
scans, inject WiFi credentials, reconnect, reboot, forget networks, and
tamper with configuration — with no token, no pairing, and no prior Google
account linkage.

Root cause: this build predates Google's **June 2019**
`cast-local-authorization-token` rollout, which added an authorization
requirement to the local Cast/setup API. This particular unit (a May 2019
build) shipped without it.

## Access surfaces

| Surface | Address | Port | Auth |
|---|---|---|---|
| Setup soft-AP (WiFi setup mode) | `https://192.168.255.249:8443` | 8443 | none |
| LAN IP (when provisioned) | e.g. `https://192.168.50.238:8443` | 8443 | none |
| mDNS `_googlecast._tcp` | `LG-WK7...local:8009` | 8009 | — |
| Open TCP ports on LAN | 8008, 8009, 8443, 9000, 9741, 10001 | — | — |

The API answers over TLS on 8443 (self-signed cert; `curl -k`). The device
serves this API both from its setup soft-AP (`192.168.255.249`, suffix
`n019`) and from its LAN address once provisioned.

## Verified endpoints

Confirmed working with NO token/header beyond the request body:

| Method | Path | Verified effect |
|---|---|---|
| GET  | `/setup/eureka_info` | Device state: wifi, setup, net, build info, stats |
| GET  | `/setup/scan_results` | Results of last WiFi scan |
| GET  | `/setup/configured_networks` | Saved network list |
| POST | `/setup/scan_wifi` | Trigger a scan |
| POST | `/setup/connect_wifi` | **Provision device to an AP (join network)** |
| POST | `/setup/set_eureka_info` | Set device configuration |
| POST | `/setup/reboot` | Reboot device (`{"params":"now"}`); other targets untested |
| POST | `/setup/forget_wifi` | Remove a saved network |
| POST | `/setup/get_app_device_id` | Device id |
| POST | `/setup/accept_tos` | Accept terms (unlocks full API) |

## The provisioning primitive (highest impact)

`POST /setup/connect_wifi` provisions the device to an access point chosen by
the flashing operator. Confirmed end-to-end on a controlled AP and on a real home network
(`horizon`):

1. Device publishes an RSA-2048 `public_key` (via the setup API).
2. The flashing operator RSA-2048 encrypts the target AP's WPA-PSK with that key.
3. Base64 it and POST to `/setup/connect_wifi`.
4. Device decrypts, authenticates, joins the chosen network.

On join it picks up a LAN IP, reports `net.online: true`, `wpa_state: 10`,
and advertises Cast over mDNS — i.e. the operator can steer the device onto
**their own network/infrastructure** as a base for flashing work.

The API also answers **without any `cast-local-authorization-token`** and
without a completed Google Home / account setup.

## Device flashing implications

These are the capabilities that make this API a useful first step toward
flashing a bootloader-locked WK7 (the end goal being a root shell / ADB, from
which the flashing stack in `/data/wk7linux` can be run):

- **WiFi credential / network injection**: full provisioning of the device to
  an access point chosen by the flashing operator.
- **Network positioning**: bring the device onto an arbitrary network of the
  operator's choosing, then serve it arbitrary content or services from there
  during the flashing process.
- **WiFi recon**: the `/setup/scan_*` endpoints reveal nearby BSSIDs/SSIDs.
- **Reset / mode cycling**: unauthenticated reboot, forget_wifi, and config
  tampering — useful for cycling the device between states while flashing.
- **Settings tampering**: `set_eureka_info` mutates device configuration.

Caveat on scope: even with these primitives, RCE / code execution was
**not** reached from this API in testing. The Cast app registry on this unit
is empty (and it can't stay provisioned without a completed Google Home
setup), so the verified capability is **device control and network
positioning**, not a direct root/flash primitive.

## Scope / not verified

These remain **unverified** and are noted to avoid overclaiming:

| Item | Status |
|---|---|
| `reboot` into `bootloader` / `recovery` / `edl` modes | ⚠️ Untested on this unit |
| Reaching ADB / root shell via the API | ❌ Not achieved |
| Full enumeration of all `/setup/*` routes | ⚠️ Partial |
| Persistence once provisioned (device fell back to setup mode in minutes) | ⚠️ Unstable |

## Reversibility / remediation notes

- The device **cleanly reverts to setup mode** when it cannot stay provisioned
  (`setup_state: 10`, re-advertises the setup AP), so the loop is reversible
  — a network-forgery victim can be reset back to factory setup.
- No firmware fix: Google applied the auth-token requirement to *newer* build
  lines only; this May 2019 build is permanently out of support (Android
  Things EOL, Oct 2017 patch level). There is no update to harden this unit.

## Key facts to cite

- Google Cast security: `cast-local-authorization-token` — introduced
  **June 2019** for the local Cast protocol; builds earlier than that (this
  unit is May 2019) do not require it.
- DEF CON 2019 Chromecast talk documented an unauthenticated
  `contentUrl -> Chromium` media-delivery primitive that depends on the Cast
  Default Media Receiver app being present; that app registry is **empty**
  on this unit (`GET_APP_AVAILABILITY` → `APP_UNAVAILABLE` for `CC1AD845`,
  `233637DE`, ...; `LAUNCH` → `NOT_FOUND`), so that primitive cannot be
  exercised here.