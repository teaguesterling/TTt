#!/usr/bin/env python3
"""agent-catalog-proxy — transparent reverse proxy for agent-services.api.tiiny.

The native-Linux TiinyOS client reports platform "linux-x86-64"; several agents
(OpenCode, Hermes) are perfectly runnable on Linux but their catalog entries only
list darwin/windows platforms, so the store's OS filter hides them. This proxy
forwards every request to the device unchanged EXCEPT GET /api/v1/apps, where it
appends a synthetic "linux-x86-64" platform to those agents so they pass the
filter. No app modification; fully reversible (stop the proxy, drop the host map).

env:
  PROXY_PORT        listen port on 127.0.0.1 (default 60080)
  PROXY_LINUX_APPS  comma-separated app_ids to linux-enable (default: opencode)
  PROXY_DEVICE_HOST Host header + vhost to forward as (default agent-services.api.tiiny)
  PCSVR_HOSTS       hosts file to read the device IP from
"""
import http.server, http.client, json, os, sys, socketserver

PORT        = int(os.environ.get("PROXY_PORT", "60080"))
LINUX_APPS  = {x for x in os.environ.get("PROXY_LINUX_APPS", "opencode").split(",") if x}
DEVICE_HOST = os.environ.get("PROXY_DEVICE_HOST", "agent-services.api.tiiny")
HOSTS       = os.path.expanduser(os.environ.get("PCSVR_HOSTS", "~/.local/share/tiiny-pcsvr/hosts"))

def device_ip():
    try:
        for line in open(HOSTS):
            if "tiiny" in line and not line.strip().startswith(("127.", "#")):
                return line.split()[0]
    except Exception:
        pass
    return None

def inject_linux(raw):
    d = json.loads(raw)
    apps = d.get("app") if isinstance(d, dict) else d
    if not isinstance(apps, list):
        return raw
    n = 0
    for a in apps:
        if a.get("app_id") in LINUX_APPS:
            plats = a.get("platforms") or []
            if plats and not any(p.get("name") == "linux-x86-64" for p in plats):
                p = dict(plats[0]); p["name"] = "linux-x86-64"
                plats.append(p); a["platforms"] = plats; n += 1
    if n:
        sys.stderr.write(f"[proxy] injected linux-x86-64 into {n} agent(s): {LINUX_APPS}\n")
    return json.dumps(d).encode()

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def _forward(self):
        ip = device_ip()
        if not ip:
            self.send_error(502, "device ip unknown"); return
        n = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(n) if n else None
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in ("host", "content-length", "connection")}
        headers["Host"] = DEVICE_HOST
        try:
            conn = http.client.HTTPConnection(ip, 80, timeout=30)
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
        except Exception as e:
            self.send_error(502, f"upstream: {e}"); return
        if self.command == "GET" and self.path.split("?")[0] == "/api/v1/apps" and resp.status == 200:
            try: data = inject_linux(data)
            except Exception as e: sys.stderr.write(f"[proxy] inject error: {e}\n")
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in ("content-length", "transfer-encoding", "connection"): continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        try: self.wfile.write(data)
        except Exception: pass
        conn.close()
    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = _forward
    def log_message(self, *a): pass

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

if __name__ == "__main__":
    sys.stderr.write(f"[proxy] agent-catalog-proxy on 127.0.0.1:{PORT} -> {DEVICE_HOST}@{device_ip()} "
                     f"(linux-enable: {sorted(LINUX_APPS)})\n")
    Server(("127.0.0.1", PORT), Handler).serve_forever()
