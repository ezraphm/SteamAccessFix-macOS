#!/bin/sh
"true" '''\'
[ "$(id -u)" -eq 0 ] || exec sudo python3 "$0" "$@"
exec python3 "$0" "$@"
'''
"""SteamAccessFix for macOS. Double-click or run: ./SteamAccessFix.command  (Ctrl-C restores everything).
Recover after a hard kill: ./SteamAccessFix.command --restore
Keep system DNS: --nodns | DNS only, no proxy: --dns-only | Pick DNS: --dns <name>|fastest
Auto MTU (PPPoE): --mtu"""
import asyncio, concurrent.futures, json, os, random, re, signal, socket, struct, subprocess, sys, time

PORT = 31627                      # one port: CONNECT proxy + PAC (GET /proxy.pac)
PAC = ""
DOMAINS = ["steampowered.com", "steamcommunity.com", "steamstatic.com", "steamusercontent.com",
           "steam-chat.com", "steamgames.com", "steamcontent.com", "steamserver.net",
           "counter-strike.net", "dota2.com", "valvesoftware.com"]
DNS_SETS = {"google": ["8.8.8.8", "8.8.4.4"], "cloudflare": ["1.1.1.1", "1.0.0.1"],
            "controld": ["76.76.2.0", "76.76.10.0"], "quad9": ["9.9.9.9", "149.112.112.112"],
            "opendns": ["208.67.222.222", "208.67.220.220"], "adguard": ["94.140.14.14", "94.140.15.15"],
            "nextdns": ["45.90.28.0", "45.90.30.0"], "alidns": ["223.5.5.5", "223.6.6.6"],
            "dnssb": ["185.222.222.222", "45.11.45.11"], "comodo": ["8.26.56.26", "8.20.247.20"]}
GAME_PROCS = ["steam_osx", "dota2", "cs2"]   # flush DNS cache when one starts
STATE = "/var/tmp/saf-state.json"
KEEP_DNS = "--nodns" in sys.argv   # keep system DNS (static-IP / LAN setups)
DNS_ONLY = "--dns-only" in sys.argv  # level 1: set DNS only, no proxy/PAC
DNS_NAME = sys.argv[sys.argv.index("--dns") + 1] if "--dns" in sys.argv[:-1] else "google"
if DNS_NAME not in DNS_SETS and DNS_NAME != "fastest":
    raise SystemExit(f"--dns must be one of: fastest, {', '.join(DNS_SETS)}")
MTU = "--mtu" in sys.argv          # opt-in: probe path MTU with DF pings
DNS_TTL = 900                      # upstream: 15 min cache, avoids mid-session drops
_dns_cache = {}


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
    st = {"svc": svc, "keep_dns": KEEP_DNS, "dns": [] if "aren't any" in dns else dns.split(),
          "pac_url": url.group(1) if url and url.group(1) != "(null)" else "", "pac_on": on,
          "mtu": int(m.group(1)) if (m := re.search(r"Current Setting: (\d+)", sh("networksetup", "-getMTU", svc))) else 0}
    with open(STATE, "w") as f:
        json.dump(st, f)


def restore():
    if not os.path.exists(STATE):
        return
    st = json.load(open(STATE))
    svc = st["svc"]
    if not st.get("keep_dns"):
        subprocess.run(["networksetup", "-setdnsservers", svc, *(st["dns"] or ["Empty"])])
    if st["pac_url"]:
        subprocess.run(["networksetup", "-setautoproxyurl", svc, st["pac_url"]])
    subprocess.run(["networksetup", "-setautoproxystate", svc, "on" if st["pac_on"] else "off"])
    if st.get("mtu"):
        subprocess.run(["networksetup", "-setMTU", svc, str(st["mtu"])], capture_output=True)
    flush_dns()
    os.remove(STATE)
    print("restored", svc)


def flush_dns():
    subprocess.run(["dscacheutil", "-flushcache"])
    subprocess.run(["killall", "-HUP", "mDNSResponder"], capture_output=True)


def resolve_doh(host):
    hit = _dns_cache.get(host)
    if hit and hit[1] > time.monotonic():
        return hit[0]
    ip = _resolve(host)
    _dns_cache[host] = (ip, time.monotonic() + DNS_TTL)
    return ip


def dns_query(host, server, timeout=4):
    """Plain UDP A query; returns first IPv4. Raises on timeout/parse error."""
    q = struct.pack(">HHHHHH", random.randint(0, 65535), 0x0100, 1, 0, 0, 0)
    for label in host.split("."):
        q += bytes([len(label)]) + label.encode()
    q += b"\x00" + struct.pack(">HH", 1, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sk:
        sk.settimeout(timeout)
        sk.sendto(q, (server, 53))
        r = sk.recv(512)
    i = 12
    while r[i]: i += r[i] + 1
    i += 5
    for _ in range(struct.unpack(">H", r[6:8])[0]):
        if r[i] & 0xC0 == 0xC0: i += 2
        else:
            while r[i]: i += r[i] + 1
            i += 1
        typ, _c, _ttl, rdl = struct.unpack(">HHIH", r[i:i+10]); i += 10
        if typ == 1: return socket.inet_ntoa(r[i:i+4])
        i += rdl
    raise ValueError("no A record")


def _resolve(host):
    # Google DNS over UDP (plain DNS, not DoH). Cloudflare DoH gave a dead IP for Steam.
    try:
        return dns_query(host, "8.8.8.8")
    except Exception:
        return socket.getaddrinfo(host, 443, socket.AF_INET)[0][4][0]


def fastest_dns():
    """Time one query per provider in parallel; return (best_name, [(ms, name)...])."""
    def probe(name):
        t = time.monotonic()
        try:
            dns_query("store.steampowered.com", DNS_SETS[name][0], 2)
            return (time.monotonic() - t) * 1000, name
        except Exception:
            return float("inf"), name
    with concurrent.futures.ThreadPoolExecutor(len(DNS_SETS)) as ex:
        res = sorted(ex.map(probe, DNS_SETS))
    if res[0][0] == float("inf"):
        raise SystemExit("no DNS provider reachable")
    return res[0][1], res


def find_mtu():
    """Largest MTU passing 'ping -D' (DF set) to 1.1.1.1; binary search on payload, +28 for IP/ICMP headers."""
    ok = lambda n: subprocess.run(["ping", "-D", "-s", str(n), "-c", "1", "-t", "1", "1.1.1.1"],
                                  capture_output=True).returncode == 0
    lo, hi = 1172, 1472              # 1200..1500 MTU
    if not ok(lo):
        return 0
    while lo < hi:
        mid = (lo + hi + 1) // 2
        lo, hi = (mid, hi) if ok(mid) else (lo, mid - 1)
    return lo + 28


async def watch_games():
    """Flush DNS cache when a game process newly appears (upstream 'Game Launch Hook')."""
    seen = set()
    while True:
        now = {n for n in GAME_PROCS if subprocess.run(["pgrep", "-x", n], capture_output=True).returncode == 0}
        if now - seen:
            flush_dns()
            print(f"game started ({', '.join(sorted(now - seen))}): DNS cache flushed", flush=True)
        seen = now
        await asyncio.sleep(5)


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
        if line.startswith("GET "):
            cw.write(f"HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\n"
                     f"Content-Length: {len(PAC)}\r\nConnection: close\r\n\r\n{PAC}".encode())
            await cw.drain()
            cw.close()
            return
        if not line.startswith("CONNECT "):
            cw.write(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
            return
        host, _, port = line.split()[1].rpartition(":")
        ip = await asyncio.get_running_loop().run_in_executor(None, resolve_doh, host)
        print(f"CONNECT {host}:{port} -> {ip}", flush=True)
        sr, sw = await asyncio.wait_for(asyncio.open_connection(ip, int(port)), 15)
        sock = sw.get_extra_info("socket")
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        cw.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await cw.drain()
        first = await cr.read(16384)
        if first[:1] == b"\x16" and len(first) >= 5:   # read whole TLS record, not one TCP segment (MSS 1460)
            need = 5 + int.from_bytes(first[3:5], "big")
            while len(first) < need:
                more = await asyncio.wait_for(cr.read(need - len(first)), 15)
                if not more:
                    break
                first += more
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


async def main():
    if os.geteuid() != 0:
        raise SystemExit("run with sudo")
    svc = active_service()
    # bind first: a failed bind must not clobber a running instance's state file (port is the instance lock)
    global PAC
    if not DNS_ONLY:
        cond = " || ".join(f'dnsDomainIs(host,"{d}")' for d in DOMAINS)
        PAC = (f'function FindProxyForURL(url, host) {{ if ({cond}) '
               f'return "PROXY 127.0.0.1:{PORT}; DIRECT"; return "DIRECT"; }}')
        srv = await asyncio.start_server(handle, "127.0.0.1", PORT)
    dns = DNS_NAME
    if dns == "fastest" and not KEEP_DNS:
        dns, table = fastest_dns()
        print("DNS ping: " + ", ".join(f"{n} {ms:.0f}ms" if ms != float("inf") else f"{n} -" for ms, n in table), flush=True)
    save_state(svc)
    try:
        if not KEEP_DNS:
            subprocess.run(["networksetup", "-setdnsservers", svc, *DNS_SETS[dns]], check=True)
            flush_dns()
        else:
            dns = "kept"
        if MTU:
            if mtu := find_mtu():
                subprocess.run(["networksetup", "-setMTU", svc, str(mtu)], check=True)
                print(f"MTU set to {mtu}", flush=True)
            else:
                print("MTU probe failed (no reply with DF set); MTU unchanged", flush=True)
        asyncio.get_running_loop().create_task(watch_games())
        if DNS_ONLY:
            print(f"on: {svc}. DNS={dns}, no proxy. Ctrl-C to restore.", flush=True)
        else:
            subprocess.run(["networksetup", "-setautoproxyurl", svc, f"http://127.0.0.1:{PORT}/proxy.pac"], check=True)
            subprocess.run(["networksetup", "-setautoproxystate", svc, "on"], check=True)
            print(f"on: {svc}. DNS={dns}, PAC+proxy=127.0.0.1:{PORT}. Ctrl-C to restore.", flush=True)
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
