# SPDX-License-Identifier: AGPL-3.0-or-later
"""A scriptable stand-in for the host bus service's wake socket.

Used by the wake client's case scripts. Standard library only; run it with
`python3 -I`. Arguments are never evaluated: TEXT is sent as given, with only
the escapes listed in the usage text expanded.
"""

import os
import signal
import socket
import sys
import threading
import time

USAGE = """usage: fake-service.py SOCKET LOG ACTION...

Bind a unix stream socket at SOCKET (mode 0600), append each request line
received to LOG, and serve the Nth connection with the Nth ACTION; the last
ACTION serves every later connection. Exit on SIGTERM, removing SOCKET.

ACTION:
  reply=TEXT      send TEXT, then close
  hold            never answer; keep the connection until the client closes it
  close           close at once, without reading the request
  drip=MS:TEXT    send TEXT one byte every MS milliseconds, then close
  flood           send bytes other than LF without end
  after=MS:TEXT   wait MS milliseconds, then send TEXT and close

Every action but close first reads the request line and logs it. In TEXT,
backslash escapes \\n, \\t, \\\\ and \\xHH (two hex digits) are expanded;
any other backslash is an error.
"""

HEX = b"0123456789abcdefABCDEF"
MAX_REQUEST = 65536
REQUEST_SECONDS = 10

log_lock = threading.Lock()


def usage(problem=None):
    if problem:
        sys.stderr.write("fake-service.py: %s\n" % problem)
    sys.stderr.write(USAGE)
    sys.exit(2)


def expand(raw):
    """RAW (bytes) with the backslash escapes expanded."""
    out = bytearray()
    i = 0
    while i < len(raw):
        c = raw[i]
        if c != 0x5C:
            out.append(c)
            i += 1
            continue
        nxt = raw[i + 1:i + 2]
        if nxt == b"n":
            out.append(10)
            i += 2
        elif nxt == b"t":
            out.append(9)
            i += 2
        elif nxt == b"\\":
            out.append(0x5C)
            i += 2
        elif (nxt == b"x" and i + 4 <= len(raw)
              and all(h in HEX for h in raw[i + 2:i + 4])):
            out.append(int(raw[i + 2:i + 4], 16))
            i += 4
        else:
            raise ValueError("bad escape at offset %d" % i)
    return bytes(out)


def parse_ms_text(rest):
    ms, sep, text = rest.partition(b":")
    if not sep or not ms.isdigit():
        raise ValueError("expected MS:TEXT")
    return int(ms), expand(text)


def parse_action(arg):
    """One ACTION argument (bytes) as (kind, ms, text)."""
    if arg == b"hold":
        return ("hold", 0, b"")
    if arg == b"close":
        return ("close", 0, b"")
    if arg == b"flood":
        return ("flood", 0, b"")
    if arg.startswith(b"reply="):
        return ("reply", 0, expand(arg[6:]))
    if arg.startswith(b"drip="):
        ms, text = parse_ms_text(arg[5:])
        return ("drip", ms, text)
    if arg.startswith(b"after="):
        ms, text = parse_ms_text(arg[6:])
        return ("after", ms, text)
    raise ValueError("unknown action")


def log_request(path, line):
    with log_lock:
        with open(path, "ab") as f:
            f.write(line + b"\n")


def read_request(conn):
    """The request line without its LF, or None when none arrives."""
    conn.settimeout(REQUEST_SECONDS)
    data = b""
    while b"\n" not in data:
        if len(data) > MAX_REQUEST:
            return None
        chunk = conn.recv(4096)
        if not chunk:
            return None
        data += chunk
    conn.settimeout(None)
    return data.split(b"\n", 1)[0]


def serve(conn, action, log_path):
    kind, ms, text = action
    try:
        if kind == "close":
            return
        line = read_request(conn)
        if line is None:
            return
        log_request(log_path, line)
        if kind == "reply":
            conn.sendall(text)
        elif kind == "after":
            time.sleep(ms / 1000.0)
            conn.sendall(text)
        elif kind == "drip":
            for octet in text:
                conn.sendall(bytes([octet]))
                time.sleep(ms / 1000.0)
        elif kind == "flood":
            chunk = b"x" * 65536
            while True:
                conn.sendall(chunk)
        elif kind == "hold":
            while conn.recv(4096):
                pass
    except OSError:
        pass
    finally:
        conn.close()


def main(argv):
    if len(argv) < 4:
        usage()
    sock_path, log_path = argv[1], argv[2]
    try:
        actions = [parse_action(os.fsencode(a)) for a in argv[3:]]
    except ValueError as e:
        usage(str(e))

    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old_mask = os.umask(0o177)
    try:
        server.bind(sock_path)
    finally:
        os.umask(old_mask)
    os.chmod(sock_path, 0o600)

    def on_term(signo, frame):
        try:
            os.unlink(sock_path)
        except OSError:
            pass
        os._exit(0)

    signal.signal(signal.SIGTERM, on_term)
    server.listen(64)

    served = 0
    while True:
        conn, _ = server.accept()
        action = actions[min(served, len(actions) - 1)]
        served += 1
        threading.Thread(target=serve, args=(conn, action, log_path),
                         daemon=True).start()


if __name__ == "__main__":
    main(sys.argv)
