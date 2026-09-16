#!/usr/bin/env python3
"""Speak pcsvr's device-discovery protocol natively (Linux UDP works fine).

Validates that a Wine SIO_UDP_NETRESET fix would actually yield a discovered
device, before investing in a Wine build.

Protocol per pcsvr config.yaml:
  UDPPort 39217, RequestToken "GADGET_DISCOVER_V1", ResponseWindowMillis 800
"""
import socket, json, sys, time

TOKEN = b"GADGET_DISCOVER_V1"
PORT = 39217
WINDOW = 1.5

targets = ["255.255.255.255", "172.20.19.91", "172.20.19.89"]

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.settimeout(WINDOW)
try:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b"enx0261bcaa1602\0")
except OSError as e:
    print(f"(could not bind to usb iface: {e})")

for t in targets:
    try:
        s.sendto(TOKEN, (t, PORT))
        print(f"sent {TOKEN.decode()} -> {t}:{PORT}")
    except OSError as e:
        print(f"send to {t} failed: {e}")

print("\nlistening %.1fs for replies..." % WINDOW)
deadline = time.time() + WINDOW
got = 0
while time.time() < deadline:
    try:
        data, addr = s.recvfrom(65535)
    except socket.timeout:
        break
    got += 1
    print(f"\n*** REPLY from {addr[0]}:{addr[1]} ({len(data)} bytes) ***")
    try:
        d = json.loads(data)
        for k in ("device_name", "device_id", "serial_number", "discovery_token"):
            if k in d:
                print(f"  {k}: {d[k]}")
    except Exception:
        print("  raw:", data[:300])

print(f"\n=== {got} device(s) replied over UDP ===")
sys.exit(0 if got else 1)
