# Networking feasibility

**Goal:** the fastest direct link between a Moto G54 (Android 15) and a MacBook Air M4
(macOS 27) without a router, internet, or cloud relay.

All results below were measured on 2026-10-14 with the actual devices unless marked
*not tested*. Commands used are in `scripts/hotspot-session.sh`,
`scripts/device-wireless-test.sh` and `scripts/benchmark-transfers.sh`.

## Hardware facts (verified)

| | Moto G54 5G | MacBook Air M4 |
|---|---|---|
| OS | Android 15 (SDK 35), build `cancunf_g_sysq` | macOS 27.0.1 |
| Wi-Fi | 802.11 a/b/g/n/ac; SoftAP supports 2.4 GHz ch 1–13 **and 5 GHz ch 36–48, 149–161** (`dumpsys wifi` → `SoftApCapability`) | Wi-Fi 6E capable, supports all 2.4/5 GHz channels |
| Concurrency | Turning the hotspot on **disconnects the phone's own Wi-Fi client** (`wlan0` lost its address) | — |

## Strategy A — phone Wi-Fi hotspot (tethering) ✅ **selected primary**

| Question | Result |
|---|---|
| Can the Mac join? | **Yes.** Mac got `172.31.154.x/24`, phone is `172.31.154.181` on `ap0`, gateway = phone. |
| Router needed? | **No.** |
| Internet needed? | **No.** Transfers are local. (At the test site the hotspot also had slow mobile data; AirBridge never uses it.) |
| Mac → phone TCP | **Works** (`nc` probe + AirBridge transfers). |
| Phone → Mac TCP | **Works** (Python listener on the Mac received the probe; AirBridge transfers). |
| Client isolation / firewall | Not an issue: AirBridge traffic is between the AP host (phone) and its client (Mac); isolation only affects client↔client. |
| Stable during transfers | 60 s link-stability probe: no drops. 100 MB transfers in both directions completed and verified. |
| Throughput (2.4 GHz, as configured) | Mac → phone **5.7 MB/s**, phone → Mac **6.3 MB/s** (100 MB, SHA-256 verified). The Mac reported `802.11n, channel 10 (2 GHz, 20 MHz), MCS 7, 72 Mbps` — AirBridge saturates this link (≈ 75–85 % of the PHY rate as TCP goodput). |
| Side effects | Phone loses its Wi-Fi client connection; the Mac loses its normal Wi-Fi (and its internet unless the hotspot shares mobile data). macOS remembers the hotspot and may auto-join it later. |

**Biggest available speed-up:** the hotspot is set to *2.4 GHz / Compatible with most
devices*. The phone supports a 5 GHz SoftAP (802.11ac). Switching **Settings → Network &
internet → Hotspot & tethering → Wi-Fi hotspot → Speed & compatibility → 5 GHz** should
raise the PHY rate from 72 Mbps to 433 Mbps (80 MHz, 1×1) — an expected 3–5× faster
transfer. *Not yet measured:* changing a user's hotspot settings was deliberately left to
the user. The phone's CPU/storage are not a limit: an encrypted on-device loopback
session sustained **78.6 MB/s** (see `docs/performance.md`).

## Strategy B — Android Local-Only Hotspot (`WifiManager.startLocalOnlyHotspot`) ⚠️ implemented, not yet measured

* API 26+. Creates a random SSID/passphrase with no internet. Requires
  `NEARBY_WIFI_DEVICES` (Android 13+, declared `neverForLocation`) or
  `ACCESS_FINE_LOCATION` on Android 10–12, and `CHANGE_WIFI_STATE`.
* AirBridge implements it (Connect screen → *Start local-only hotspot*) and shows the
  SSID/password, which the user types into the Mac's Wi-Fi menu. The Mac never joins
  automatically, and AirBridge does not change macOS network settings.
* Cannot run while the regular hotspot is on (`ERROR_INCOMPATIBLE_MODE`). It was not
  tested because the regular hotspot was in use during the unattended test session.
* Limitations: the network disappears when AirBridge releases the reservation; the
  password changes every time, so the Mac has to re-join manually.

## Strategy C — Mac-hosted network ❌ not practical

* macOS Internet Sharing can create a Wi-Fi network only by sharing *another* interface
  (Ethernet/Thunderbolt) to Wi-Fi, which takes over the Mac's Wi-Fi radio. The MacBook
  Air has no built-in Ethernet (a USB LAN adapter was attached to the hub during testing,
  so this is possible in principle).
* Ad-hoc (IBSS / computer-to-computer) networks are no longer offered by macOS, and
  Android does not join IBSS networks.
* Requires changing system sharing settings; AirBridge never does this automatically.
  *Not tested.*

## Strategy D — Wi-Fi Direct / peer-to-peer ❌ not available

* Android supports Wi-Fi Direct (`WifiP2pManager`), but macOS exposes **no public Wi-Fi
  Direct API**. Apple's peer-to-peer link (AWDL, used by AirDrop) is proprietary and is
  not reachable from Android. No cross-platform interoperability is possible without
  undocumented/private APIs, so it is not advertised.

## Strategy E — existing local network (router) ⚠️ fallback, **failed at the test site**

* Both devices were on the home router `FTTH-1DA2` (Mac `192.168.1.5`, phone
  `192.168.1.6`). **ARP between them failed in both directions** and TCP gave
  `No route to host`; the Mac firewall was off. The router applies **client (AP)
  isolation**, so device-to-device traffic is impossible on this network.
* The same AirBridge build works on any LAN without isolation (manual address entry and
  Bonjour/NSD discovery are implemented). Many ISP routers enable isolation on
  guest/main SSIDs — check the router's "AP isolation"/"client isolation" setting.

## Other options considered

* **USB tethering** (phone → Mac over a cable, RNDIS/NCM) — wired, not wireless; macOS
  lacks RNDIS drivers, NCM depends on the phone. *Not tested.*
* `adb reverse` over USB — used only for development tests (≈ 4 MB/s through the ADB
  tunnel); not a product transport.

## Decision

| Role | Strategy |
|---|---|
| **Primary** | Phone hotspot (A). The Mac joins it once; AirBridge then works with no router and no internet. Recommend the 5 GHz band. |
| Alternative | Local-Only Hotspot (B) from inside the app, when the regular hotspot is unavailable. |
| Fallback | Any shared LAN without client isolation (E), with manual address entry. |

Transport is plain TCP (one connection per paired session, full duplex) with
AirBridge's own authenticated encryption (`docs/security.md`). UDP is not used;
discovery uses DNS-SD (`_airbridge._tcp`) and is optional.

## Known limitations

* The Mac's Wi-Fi can only be on one network: while on the phone hotspot it has no other
  network (internet only if the hotspot shares mobile data).
* IP addresses on the hotspot can change between sessions (observed: `.75` then `.231`).
  AirBridge re-pairs via QR or reconnects using Bonjour/NSD discovery and the last known
  address; a pairing is tied to keys, not addresses.
* Android may stop an idle hotspot after its timeout (Hotspot → *Timeout setting*).
