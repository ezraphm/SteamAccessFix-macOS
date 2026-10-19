#!/bin/sh
"true" '''\'
[ "$(id -u)" -eq 0 ] || exec sudo python3 "$0" "$@"
exec python3 "$0" "$@"
'''
"""SteamAccessFix for macOS. Double-click or run: ./SteamAccessFix.command  (Ctrl-C restores everything).
Recover after a hard kill: ./SteamAccessFix.command --restore"""
import asyncio, json, os, re, signal, socket, struct, subprocess, sys, urllib.request

PROXY_PORT, PAC_PORT = 8787, 8788
DOMAINS = ["steampowered.com", "steamcommunity.com", "steamstatic.com", "steamusercontent.com"]
GOOGLE_DNS = ["8.8.8.8", "8.8.4.4"]
STATE = "/var/tmp/saf-state.json"


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def active_service():
    dev = re.search(r"interface: (\S+)", sh("route", "-n", "get", "default")).group(1)
    order = sh("networksetup", "-listnetworkserviceorder")
    m = re.search(r"\(\d+\) ([^\n]+)\n\(Hardware Port: [^,]+, Device: " + re.escape(dev) + r"\)", order)
    if not m:
        raise SystemExit(f"no network service for device {dev}")
    return m.group(1)


def save_state(svc):
    dns = sh("networksetup", "-getdnsservers", svc).strip()
    pac = sh("networksetup", "-getautoproxyurl", svc)
    url = re.search(r"URL: (\S+)", pac)
    on = re.search(r"Enabled: Yes", pac) is not None
    st = {"svc": svc, "dns": [] if "aren't any" in dns else dns.split(),
          "pac_url": url.group(1) if url and url.group(1) != "(null)" else "", "pac_on": on}
    with open(STATE, "w") as f:
        json.dump(st, f)


def restore():
    if not os.path.exists(STATE):
        return
    st = json.load(open(STATE))
    svc = st["svc"]
    subprocess.run(["networksetup", "-setdnsservers", svc, *(st["dns"] or ["Empty"])])
    if st["pac_url"]:
        subprocess.run(["networksetup", "-setautoproxyurl", svc, st["pac_url"]])
    subprocess.run(["networksetup", "-setautoproxystate", svc, "on" if st["pac_on"] else "off"])
    flush_dns()
    os.remove(STATE)
    print("restored", svc)


def flush_dns():
    subprocess.run(["dscacheutil", "-flushcache"])
    subprocess.run(["killall", "-HUP", "mDNSResponder"], capture_output=True)


def resolve_doh(host):
    # Ask Google DNS over UDP (plain DNS, not DoH). Cloudflare DoH gave a dead IP for Steam.
    # ponytail: no TTL/cache; add when reconnect churn matters.
    import random, struct as st
    q = st.pack(">HHHHHH", random.randint(0, 65535), 0x0100, 1, 0, 0, 0)
    for label in host.split("."):
        q += bytes([len(label)]) + label.encode()
    q += b"\x00" + st.pack(">HH", 1, 1)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sk:
            sk.settimeout(4)
            sk.sendto(q, ("8.8.8.8", 53))
            r = sk.recv(512)
        ancount = st.unpack(">H", r[6:8])[0]
        i = 12
        while r[i]: i += r[i] + 1
        i += 5
        for _ in range(ancount):
            if r[i] & 0xC0 == 0xC0: i += 2
            else:
                while r[i]: i += r[i] + 1
                i += 1
            typ, _c, _ttl, rdl = st.unpack(">HHIH", r[i:i+10]); i += 10
            if typ == 1: return socket.inet_ntoa(r[i:i+4])
            i += rdl
    except Exception:
        pass
    return socket.getaddrinfo(host, 443, socket.AF_INET)[0][4][0]


def sni_span(rec):
    """Return (offset, length) of SNI host name inside a TLS ClientHello record, else None."""
    try:
        if rec[0] != 0x16 or rec[5] != 0x01:
            return None
        p = 43                       # rec hdr 5 + hs type 1 + hs len 3 + version 2 + random 32
        p += 1 + rec[p]              # session id
        p += 2 + int.from_bytes(rec[p:p + 2], "big")   # cipher suites
        p += 1 + rec[p]              # compression
        end = p + 2 + int.from_bytes(rec[p:p + 2], "big")
        p += 2
        while p + 4 <= end:
            t = int.from_bytes(rec[p:p + 2], "big")
            l = int.from_bytes(rec[p + 2:p + 4], "big")
            p += 4
            if t == 0:               # server_name: list len 2, type 1, name len 2
                return p + 5, int.from_bytes(rec[p + 3:p + 5], "big")
            p += l
    except IndexError:
        pass
    return None


async def pipe(r, w):
    try:
        while data := await r.read(65536):
            w.write(data)
            await w.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        w.close()


async def handle(cr, cw):
    try:
        head = await cr.readuntil(b"\r\n\r\n")
        line = head.split(b"\r\n", 1)[0].decode(errors="replace")
        if not line.startswith("CONNECT "):
            cw.write(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
            return
        host, _, port = line.split()[1].rpartition(":")
        ip = await asyncio.get_running_loop().run_in_executor(None, resolve_doh, host)
        print(f"CONNECT {host}:{port} -> {ip}", flush=True)
        sr, sw = await asyncio.open_connection(ip, int(port))
        sock = sw.get_extra_info("socket")
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        cw.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await cw.drain()
        first = await cr.read(16384)
        span = sni_span(first)
        if span:                     # split ClientHello after TLS record header (DPI evasion)
            cut = 5                  # ponytail: mid-SNI cut gets RST on some ISPs; this one passes. Make configurable if an ISP needs otherwise.
            sw.write(first[:cut]); await sw.drain()
            await asyncio.sleep(0.05)
            first = first[cut:]
        sw.write(first); await sw.drain()
        await asyncio.gather(pipe(cr, sw), pipe(sr, cw))
    except Exception as e:
        print(f"fail {type(e).__name__}: {e}", flush=True)
        cw.close()


async def pac_server(pac):
    async def h(r, w):
        try:
            await r.readuntil(b"\r\n\r\n")
            w.write(f"HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\n"
                    f"Content-Length: {len(pac)}\r\nConnection: close\r\n\r\n{pac}".encode())
            await w.drain()
        except (asyncio.IncompleteReadError, ConnectionError, OSError):
            pass  # client closed early (browser probes); not an error
        finally:
            w.close()
    return await asyncio.start_server(h, "127.0.0.1", PAC_PORT)


async def main():
    if os.geteuid() != 0:
        raise SystemExit("run with sudo")
    svc = active_service()
    cond = " || ".join(f'dnsDomainIs(host,"{d}")' for d in DOMAINS)
    pac = (f'function FindProxyForURL(url, host) {{ if ({cond}) '
           f'return "PROXY 127.0.0.1:{PROXY_PORT}"; return "DIRECT"; }}')
    # bind first: a failed bind must not clobber a running instance's state file
    srv = await asyncio.start_server(handle, "127.0.0.1", PROXY_PORT)
    pacs = await pac_server(pac)
    save_state(svc)
    try:
        subprocess.run(["networksetup", "-setdnsservers", svc, *GOOGLE_DNS], check=True)
        flush_dns()
        subprocess.run(["networksetup", "-setautoproxyurl", svc, f"http://127.0.0.1:{PAC_PORT}/proxy.pac"], check=True)
        subprocess.run(["networksetup", "-setautoproxystate", svc, "on"], check=True)
        print(f"on: {svc}. DNS=Google, PAC=127.0.0.1:{PAC_PORT}, proxy=127.0.0.1:{PROXY_PORT}. Ctrl-C to restore.", flush=True)
        await asyncio.Future()
    finally:
        restore()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    if "--restore" in sys.argv:
        restore()
        sys.exit(0)
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
