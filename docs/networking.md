# Networking — how to reach the device

Three paths exist. They are not equivalent, and the differences matter.

```
                    ┌─────────────────────────────────────────────────────┐
  any LAN host ───► │ dnsmasq on the bridge host   address=/tiiny/10.0.0.2│
   *.tiiny          └────────────────┬────────────────────────────────────┘
                                     ▼
                    ┌─────────────────────────────────────────────────────┐
                    │ Caddy on the bridge host :80  (podman, Network=host)│
                    └────────────────┬────────────────────────────────────┘
                                     ▼  reverse_proxy
                    ┌─────────────────────────────────────────────────────┐
                    │ 172.20.19.89:80   USB gadget, fixed /30             │
                    │                 bridge-host side = .90              │
                    └─────────────────────────────────────────────────────┘

  direct WiFi ─────► 10.0.0.50       DHCP, roam-unstable   (avoid)
  direct USB  ─────► 172.20.19.89    bridge-host-local only
```

## The three paths

| path | address | who can use it | stability |
|---|---|---|---|
| **Bridge (default)** | `*.tiiny` names | any LAN host | best — fixed /30, no roam |
| **Direct USB** | `172.20.19.89` | only the host it's plugged into (the bridge host) | best, but local |
| **Direct WiFi** | `10.0.0.50` | any LAN host | **poor** — DHCP drift + roam wedges |

**Always prefer the names.** The WiFi address is DHCP-assigned — it has moved
before — and sits behind a radio with a documented sticky-roam failure. Pinning
anything to it is how you get a stale address *and* an unreliable path.

`TIINY_IP` forces the direct path when you need it: off-LAN, the bridge host
down, or debugging the bridge itself.

## What rides the bridge — and what doesn't

Caddy proxies **port 80 only**, and the device's own nginx decides what port 80
exposes. Measured:

| path | direct `:8800` | via the bridge |
|---|---|---|
| `/v1/*` — OpenAI surface | 200 | **200** |
| `/api/v1/models/*` — management | 200 | **200** |
| `/api/tags`, `/api/ps` — Ollama surface | 200 | **404** |
| `/health` | 200 | **404** |

Two consequences worth internalising:

- **`<ip>:8800` is not reachable over the bridge.** Use the **`p8800.api.tiiny`**
  vhost on :80 — the device's nginx maps it to the internal 8800. This is why the
  tools no longer dial `:8800`.
- **The Ollama-compatible surface exists only on a direct connection.** So the
  stock Ollama harness can drive this device from the bridge host, and cannot
  from anywhere else. For woollamad: the `device` management protocol rides the
  bridge, the `ollama` protocol does not.

Vhost choice barely matters otherwise — `api.tiiny`, `openai.api.tiiny`,
`ollama.api.tiiny` and `p8800.api.tiiny` all serve `/v1/*`. The names are
organisational.

## Why the bridge exists

Two failure modes it removes, both of which cost real time:

**1. The WiFi roams badly.** MediaTek MT7922 / `mt7921e` on a dense multi-vendor
mesh with no 802.11r/k/v. The firmware clings to a degrading AP well past the
point the data path dies: the association reports **`signal_strength: 100`**
while passing zero traffic, for windows up to **~19 minutes**. Confirmed
device-specific — during one dead window, three other WiFi hosts on the same mesh
pinging the same gateway had **100% uptime** while the device had 21%.

It self-heals when the driver finally forces a re-association (`wlan0: Driver
requested disconnection from AP …`), and recovery takes ~7 seconds once it lets
go. The delay is entirely in how long it takes to notice the link is dead —
once it does, recovery is fast.

**2. Client-side DNS shims were fragile.** The desktop app used to get `*.tiiny`
resolution only from its launcher — `nss_wrapper` for the main process,
Chromium `--host-resolver-rules` for the renderer. Two ways that broke:

- any launch path that bypassed the launcher got **no device DNS at all**
  (an autostart entry did exactly this);
- the renderer rules were **baked at launch**, so a DHCP change stranded it until
  a full app restart.

Real DNS makes both structurally impossible. The shims are retired but preserved
behind `TIINY_DNS_SHIM=1`.

## The USB link

A CDC gadget presenting a fixed **/30**: device `172.20.19.89`, host `.90`. It
does **not** roam — flat ~2ms, lossless. It came up unassisted on a second host
(NetworkManager DHCP, no manual config, `cdc_ncm`/`cdc_ether`/`usbnet`), so it
isn't paired to one machine.

**It carries inbound only.** The device's own default route is still `wlan0`:

```
default via 10.0.0.1 dev wlan0
172.20.19.88/30 dev usb0 proto kernel scope link src 172.20.19.89
```

`usb0` is link-scope with no default route, so the device's *outbound* traffic —
model downloads, cloud APIs — still rides the unreliable radio. Measured during a
51.8 GiB download: `wlan0 rx 53 MB/s`, `usb0 rx 0 KB/s`.

**This is why large downloads still fail.** Giving the device outbound over USB
would need IP-forward + masquerade on the bridge host; deliberately not done.

## DNS specifics

dnsmasq on the bridge host, in a `dnsmasq.d` config file:

```
address=/tiiny/10.0.0.2
```

**dnsmasq's `address=/domain/` is a suffix match at any depth**, so this one line
covers `api.tiiny` *and* `auth.api.tiiny`. A **Caddy** wildcard is single-label —
`*.tiiny` would miss the two-label names — which is why the Caddy snippet lists
all 16 names explicitly. The two look alike and behave differently; this is easy
to get wrong.

Clients need their resolver pointed at the bridge host
(`/etc/systemd/resolved.conf.d/lan.conf`, `DNS=10.0.0.2`).

⚠️ **Known soft spot:** that drop-in sets `Domains=~lan`, which only *routes*
`.lan` to the bridge host. `.tiiny` works because resolved queries both link
servers and dnsmasq answers authoritatively while the LAN's router NXDOMAINs —
but that's a race, not a guarantee. Adding `~tiiny` to the `Domains` line would
make it deterministic.

## ⚠️ The bridge caps any request at 60 seconds

The Caddy config sets `response_header_timeout 60s` on the
`reverse_proxy`. Caddy waits that long for the **response headers**, and a
non-streaming inference request sends nothing until generation finishes — so
**any generation over 60s returns HTTP 504 through a `.tiiny` name**, even
though the device is working fine and will complete.

Measured 2026-08-17, same request, same payload (8.5 MB image):

```
via p8800.api.tiiny (bridge)   504 after  60.2s
direct 10.0.0.50:8800          200 after 180.7s   (9095 chars returned)
```

It looks exactly like a device failure, and it is not. It also cannot be
distinguished from a real timeout without trying the direct path.

**Three ways out, in order of preference:**

1. **Stream.** `"stream": true` makes the device send headers immediately, so
   the timeout never arms. Best fix for clients that can take a stream.
2. **Raise the ceiling.** Set `response_header_timeout 600s` in the Caddy
   config. Inference here reaches 257s on a dense page; 60s was chosen before
   anything long ran through the bridge. (Not applied in this config.)
3. **Go direct** to `<device-ip>:8800` for known-slow work. Loses the bridge's
   stability, so only for batch jobs you're watching.

Rule of thumb: bridge for interactive and management traffic, direct or
streaming for image input and long generations.

## Not served by the bridge

`:5005` — the `connectors` service (third-party account integrations and an MCP
registry). Reachable directly over both WiFi and USB, but not proxied through
the bridge, so a `.tiiny` name will not reach it.
