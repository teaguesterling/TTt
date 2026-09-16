#!/usr/bin/env python3
"""Find the Tiiny device and write its address where TiinyOS needs it.

The app dials http://auth.api.tiiny.local/api/v1/connect -- port 80, hardcoded
in app.asar, no override. Two facts make that easy to satisfy:

  * the DEVICE serves that vhost on its own port 80 (nginx keyed on the
    hostname), so nothing local needs to bind privileged port 80;
  * Wine ignores the prefix's drivers/etc/hosts and delegates to the Unix
    resolver, so the name has to be resolvable on the Linux side.

We solve the second with nss_wrapper (LD_PRELOAD, per-process) rather than
systemd-resolved, so nothing on the host is permanently modified.

Writes:
  ~/.local/share/tiiny-pcsvr/hosts             -- for NSS_WRAPPER_HOSTS
  ~/.local/share/tiiny-pcsvr/etc/pcsvr-api.yaml -- DNS DefaultIPv4

Discovery uses pcsvr's own protocol natively (Linux UDP works fine): broadcast
the RequestToken on UDP 39217 and read the JSON reply. Exit 0 on success.
"""
import json
import os
import re
import socket
import sys

TOKEN = b"GADGET_DISCOVER_V1"
PORT = 39217
WINDOW = 2.0

BASE = os.path.expanduser(os.environ.get("PCSVR_DIR", "~/.local/share/tiiny-pcsvr"))
CFG = os.path.join(BASE, "etc", "pcsvr-api.yaml")
HOSTS = os.path.join(BASE, "hosts")

# Names the app resolves, all served by the device's nginx as Host-keyed
# vhosts. Note the inconsistency: auth is on the ".tiiny.local" domain while
# everything else is on a bare ".tiiny" pseudo-TLD -- so pcsvr's DNS server
# (Domain: tiiny.local) would not cover most of these even on Windows.
# Deliberately EXCLUDES real internet hosts (api.tiiny.ai, files.tiinycdn.com,
# service.dev.tiiny-svr.com) which must keep resolving normally.
NAMES = [
    # 0.9.0 dials auth on ".tiiny.local"; 0.9.6 dropped the suffix and dials the
    # bare "auth.api.tiiny". Both are listed so either version resolves -- with
    # only the .local form, 0.9.6's /connect fails with "fetch failed" and the
    # app sits on the EnterPassword screen forever.
    "auth.api.tiiny", "auth.api.tiiny.local", "api.tiiny.local",
    "api.tiiny", "agent.tiiny", "ai.tiiny", "mcp.main.tiiny",
    "agent-services.api.tiiny", "anthropic.api.tiiny", "chat-history.api.tiiny",
    "connector.api.tiiny", "hardware-upgrade.api.tiiny", "kb.api.tiiny",
    "ollama.api.tiiny", "openai.api.tiiny", "p8800.api.tiiny",
    "tts.api.tiiny", "wifi.api.tiiny",
]


def broadcast_targets():
    """Per-interface broadcast addrs, so we reach USB-gadget /30 links."""
    targets = ["255.255.255.255"]
    try:
        import fcntl, struct, array
        names = array.array('B', b'\0' * 4096)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        n = struct.unpack('iL', fcntl.ioctl(
            s.fileno(), 0x8912,  # SIOCGIFCONF
            struct.pack('iL', 4096, names.buffer_info()[0])))[0]
        data = names.tobytes()[:n]
        for i in range(0, n, 40):
            nm = data[i:i + 16].split(b'\0', 1)[0].decode()
            if not nm or nm == 'lo':
                continue
            try:
                brd = fcntl.ioctl(s.fileno(), 0x8919,  # SIOCGIFBRDADDR
                                  struct.pack('256s', nm.encode()[:15]))
                targets.append(socket.inet_ntoa(brd[20:24]))
            except OSError:
                pass
    except Exception:
        pass
    return list(dict.fromkeys(targets))


def discover():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(WINDOW)
    for t in broadcast_targets():
        try:
            s.sendto(TOKEN, (t, PORT))
        except OSError:
            pass
    try:
        while True:
            data, addr = s.recvfrom(65535)
            try:
                d = json.loads(data)
            except ValueError:
                continue
            if d.get("discovery_token") == TOKEN.decode():
                return addr[0], d.get("device_name", "?")
    except socket.timeout:
        return None, None


ip, name = discover()
if not ip:
    print("no Tiiny device replied to UDP discovery", file=sys.stderr)
    sys.exit(1)

os.makedirs(os.path.dirname(HOSTS) or ".", exist_ok=True)
with open(HOSTS, "w") as f:
    f.write("127.0.0.1 localhost\n")
    f.write("%s %s\n" % (ip, " ".join(NAMES)))

if os.path.exists(CFG):
    with open(CFG) as f:
        cfg = f.read()
    new = re.sub(r'(\n\s*DefaultIPv4:\s*)\S+', r'\g<1>' + ip, cfg, count=1)
    if new != cfg:
        with open(CFG, "w") as f:
            f.write(new)

print("found %s at %s -> %s" % (name, ip, HOSTS))
