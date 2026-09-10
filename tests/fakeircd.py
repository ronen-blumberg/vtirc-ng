#!/usr/bin/env python3
"""
tests/fakeircd.py -- a small scripted IRC server for vtirc-ng integration tests.

  fakeircd.py <base_port> <workdir>

  base_port     plain IRC
  base_port+1   IRC over TLS (self-signed certificate created in workdir)
  base_port+2   SOCKS5 proxy (no auth) that can reach the two ports above

Supports CAP LS/REQ/END, SASL PLAIN (account "acct" / password "pw"),
NICK/USER, 433 for the nick "taken", JOIN/PART/PRIVMSG/NOTICE/TOPIC/NAMES,
WHOIS, PING/PONG and echo-message with server-time tags. The virtual user
"bot" sits in #test and answers "!hello". Sending "!drop" makes the server
close that connection (reconnect test). Everything runs until killed.
"""
import base64
import os
import socket
import socketserver
import ssl
import subprocess
import sys
import threading
import time

LOCK = threading.RLock()
CLIENTS = {}          # nick(lower) -> Client
CHANNELS = {}         # name(lower) -> {"name":..., "members": [nick...], "topic": ""}
CAPS = "multi-prefix sasl server-time away-notify echo-message"


def now_tag():
    t = time.time()
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int((t % 1) * 1000)


class Client:
    def __init__(self, sock):
        self.sock = sock
        self.nick = None
        self.user = None
        self.registered = False
        self.cap_negotiating = False
        self.caps = set()
        self.sasl = False
        self.account = None
        self.buf = b""

    def send(self, line):
        try:
            self.sock.sendall((line + "\r\n").encode("utf-8", "replace"))
        except OSError:
            pass

    def prefix(self):
        return "%s!%s@fake.host" % (self.nick, self.user or "u")


def reply(c, num, text):
    c.send(":fake.server %s %s %s" % (num, c.nick or "*", text))


def deliver(target_nick, line, tagged_line=None):
    with LOCK:
        cl = CLIENTS.get(target_nick.lower())
    if cl:
        if tagged_line and "server-time" in cl.caps:
            cl.send(tagged_line)
        else:
            cl.send(line)


def chan_broadcast(chan, line, exclude=None, tagged=False):
    with LOCK:
        members = list(CHANNELS[chan.lower()]["members"])
    for m in members:
        if exclude and m.lower() == exclude.lower():
            continue
        if m == "bot":
            continue
        deliver(m, line, ("@time=%s " % now_tag()) + line if tagged else None)


def try_register(c):
    if c.registered or c.cap_negotiating or not c.nick or not c.user:
        return
    c.registered = True
    reply(c, "001", ":Welcome to FakeNet %s" % c.nick)
    reply(c, "002", ":Your host is fake.server")
    reply(c, "005", "PREFIX=(ov)@+ CHANTYPES=# NETWORK=FakeNet CASEMAPPING=rfc1459 MODES=4 :are supported by this server")
    reply(c, "375", ":- fake.server Message of the day -")
    reply(c, "372", ":- welcome to the vtirc-ng test server")
    reply(c, "376", ":End of /MOTD command.")


def handle(c, line):
    parts = line.split(" ")
    if line.startswith("@"):
        parts = parts[1:]
    cmd = parts[0].upper()
    args = parts[1:]
    trailing = None
    if " :" in line:
        trailing = line.split(" :", 1)[1]

    if cmd == "CAP":
        sub = args[0].upper() if args else ""
        if sub == "LS":
            c.cap_negotiating = True
            c.send(":fake.server CAP * LS :" + CAPS)
        elif sub == "REQ":
            req = (trailing or "").split()
            ok = [r for r in req if r in CAPS.split()]
            c.caps.update(ok)
            c.send(":fake.server CAP * ACK :" + " ".join(ok))
        elif sub == "END":
            c.cap_negotiating = False
            try_register(c)
    elif cmd == "AUTHENTICATE":
        if args and args[0] == "PLAIN":
            c.send("AUTHENTICATE +")
        elif args:
            try:
                authz, authc, pw = base64.b64decode(args[0]).decode().split("\0")
            except Exception:
                authc, pw = "", ""
            if authc == "acct" and pw == "pw":
                c.account = authc
                reply(c, "900", "%s acct :You are now logged in as acct" % (c.nick or "*"))
                reply(c, "903", ":SASL authentication successful")
            else:
                reply(c, "904", ":SASL authentication failed")
    elif cmd == "NICK":
        nn = args[0] if args else ""
        with LOCK:
            taken = nn.lower() == "taken" or (nn.lower() in CLIENTS and CLIENTS[nn.lower()] is not c)
            if not taken:
                if c.nick and c.nick.lower() in CLIENTS:
                    del CLIENTS[c.nick.lower()]
                old = c.prefix() if c.nick else None
                c.nick = nn
                CLIENTS[nn.lower()] = c
        if taken:
            reply(c, "433", "%s :Nickname is already in use" % nn)
        else:
            if c.registered and old:
                c.send(":%s NICK %s" % (old, nn))
            try_register(c)
    elif cmd == "USER":
        c.user = args[0] if args else "u"
        try_register(c)
    elif cmd == "PING":
        c.send(":fake.server PONG fake.server :" + (trailing or (args[0] if args else "")))
    elif cmd == "PONG":
        pass
    elif cmd == "JOIN":
        for ch in args[0].split(","):
            key = ch.lower()
            with LOCK:
                if key not in CHANNELS:
                    CHANNELS[key] = {"name": ch, "members": [], "topic": ""}
                if c.nick not in CHANNELS[key]["members"]:
                    CHANNELS[key]["members"].append(c.nick)
                info = CHANNELS[key]
            chan_broadcast(ch, ":%s JOIN %s" % (c.prefix(), info["name"]))
            if info["topic"]:
                reply(c, "332", "%s :%s" % (info["name"], info["topic"]))
            names = []
            for i, m in enumerate(info["members"]):
                names.append(("@" if i == 0 else "") + m)
            reply(c, "353", "= %s :%s" % (info["name"], " ".join(names)))
            reply(c, "366", "%s :End of /NAMES list." % info["name"])
    elif cmd == "PART":
        ch = args[0]
        with LOCK:
            info = CHANNELS.get(ch.lower())
        if info:
            chan_broadcast(ch, ":%s PART %s" % (c.prefix(), info["name"]))
            with LOCK:
                if c.nick in info["members"]:
                    info["members"].remove(c.nick)
    elif cmd == "TOPIC":
        ch = args[0]
        with LOCK:
            info = CHANNELS.get(ch.lower())
        if info and trailing is not None:
            info["topic"] = trailing
            chan_broadcast(ch, ":%s TOPIC %s :%s" % (c.prefix(), info["name"], trailing))
    elif cmd == "LIST":
        reply(c, "321", "Channel :Users  Name")
        with LOCK:
            chans = list(CHANNELS.values())
        for info in chans:
            reply(c, "322", "%s %d :%s" % (info["name"], len(info["members"]), info["topic"]))
        reply(c, "322", "#hebrew-עברית 7 :ערוץ בעברית")
        reply(c, "322", "#linux 1234 :Linux support")
        reply(c, "323", ":End of /LIST")
    elif cmd == "MODE":
        if args and args[0].startswith("#"):
            reply(c, "324", "%s +nt" % args[0])
    elif cmd in ("PRIVMSG", "NOTICE"):
        target = args[0]
        text = trailing or ""
        line_out = ":%s %s %s :%s" % (c.prefix(), cmd, target, text)
        if target.startswith("#"):
            with LOCK:
                info = CHANNELS.get(target.lower())
            if not info:
                reply(c, "403", "%s :No such channel" % target)
                return
            chan_broadcast(target, line_out, exclude=c.nick)
            if "echo-message" in c.caps:
                c.send("@time=%s %s" % (now_tag(), line_out))
            if text == "!drop":
                c.sock.close()
                return
            if text.startswith("!hello") and "bot" in info["members"]:
                chan_broadcast(target, ":bot!bot@fake.host PRIVMSG %s :hello %s" % (info["name"], c.nick), tagged=True)
            if text == "!pm":
                c.send(":bot!bot@fake.host PRIVMSG %s :psst, a private hello" % c.nick)
            if text.startswith("!lines"):
                n = int(text.split()[1]) if len(text.split()) > 1 else 50
                for i in range(n):
                    chan_broadcast(target, ":bot!bot@fake.host PRIVMSG %s :line %d of %d -- see https://example.org/page%d" % (info["name"], i + 1, n, i + 1))
            if text == "!op":
                chan_broadcast(target, ":bot!bot@fake.host MODE %s +o %s" % (info["name"], c.nick))
        else:
            with LOCK:
                exists = target.lower() in CLIENTS
            if target.lower() == "nickserv":
                c.send(":NickServ!NickServ@services. NOTICE %s :You said: %s" % (c.nick, text))
            elif exists:
                deliver(target, line_out)
            else:
                reply(c, "401", "%s :No such nick/channel" % target)
            if "echo-message" in c.caps:
                c.send("@time=%s %s" % (now_tag(), line_out))
    elif cmd == "WHOIS":
        who = args[-1]
        with LOCK:
            tc = CLIENTS.get(who.lower())
        if who == "bot" or tc:
            reply(c, "311", "%s %s fake.host * :%s" % (who, "bot" if who == "bot" else tc.user, "Friendly Bot" if who == "bot" else "Real Name"))
            reply(c, "319", "%s :@#test" % who)
            reply(c, "312", "%s fake.server :The fake server" % who)
            reply(c, "318", "%s :End of /WHOIS list." % who)
        else:
            reply(c, "401", "%s :No such nick/channel" % who)
            reply(c, "318", "%s :End of /WHOIS list." % who)
    elif cmd == "QUIT":
        c.send("ERROR :Closing link (%s)" % (trailing or "quit"))
        try:
            c.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
    elif c.registered:
        reply(c, "421", "%s :Unknown command" % cmd)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        c = Client(self.request)
        try:
            while True:
                data = self.request.recv(4096)
                if not data:
                    break
                c.buf += data
                while b"\n" in c.buf:
                    ln, c.buf = c.buf.split(b"\n", 1)
                    ln = ln.rstrip(b"\r").decode("utf-8", "replace")
                    if ln:
                        handle(c, ln)
        except OSError:
            pass
        finally:
            with LOCK:
                if c.nick and CLIENTS.get(c.nick.lower()) is c:
                    del CLIENTS[c.nick.lower()]
                for info in CHANNELS.values():
                    if c.nick in info["members"]:
                        info["members"].remove(c.nick)


class TLSServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, addr, handler, ctx):
        super().__init__(addr, handler)
        self.ctx = ctx

    def get_request(self):
        sock, addr = super().get_request()
        return self.ctx.wrap_socket(sock, server_side=True), addr


class Plain(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class Socks5(socketserver.BaseRequestHandler):
    def handle(self):
        s = self.request
        try:
            head = s.recv(2)
            s.recv(head[1])
            s.sendall(b"\x05\x00")
            req = s.recv(4)
            atyp = req[3]
            if atyp == 3:
                ln = s.recv(1)[0]
                host = s.recv(ln).decode()
            elif atyp == 1:
                host = socket.inet_ntoa(s.recv(4))
            else:
                s.sendall(b"\x05\x08\x00\x01" + b"\0" * 6)
                return
            port = int.from_bytes(s.recv(2), "big")
            up = socket.create_connection((host, port), timeout=5)
            s.sendall(b"\x05\x00\x00\x01" + b"\0" * 6)
            def pump(a, b):
                try:
                    while True:
                        d = a.recv(4096)
                        if not d:
                            break
                        b.sendall(d)
                except OSError:
                    pass
                finally:
                    try:
                        b.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
            t = threading.Thread(target=pump, args=(up, s), daemon=True)
            t.start()
            pump(s, up)
            t.join()
        except Exception:
            pass


def main():
    base = int(sys.argv[1])
    work = sys.argv[2]
    os.makedirs(work, exist_ok=True)
    crt = os.path.join(work, "fake.crt")
    key = os.path.join(work, "fake.key")
    if not os.path.exists(crt):
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
                        "-out", crt, "-days", "2", "-subj", "/CN=localhost"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    CHANNELS["#test"] = {"name": "#test", "members": ["bot"], "topic": "Welcome to #test"}
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(crt, key)
    servers = [Plain(("127.0.0.1", base), Handler), TLSServer(("127.0.0.1", base + 1), Handler, ctx),
               Plain(("127.0.0.1", base + 2), Socks5)]
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    print("fakeircd ready", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
