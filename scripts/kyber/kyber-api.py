#!/usr/bin/env python3
"""Minimal client for the KYBER API (gRPC), used by the AMP template.

Standard library only; HTTP/2 transport is done by curl. Messages are
encoded by hand from Module/Proto/kyber_api.proto in the KYBER repository.

Usage:
  kyber-api.py whoami
  kyber-api.py server-id                 # id of this server (matched by name)
  kyber-api.py run <command...>          # ServerManagement.RunCommand
  kyber-api.py admins                    # list moderators of this server
  kyber-api.py sync-admins [--remove-others] <name-or-id>...

Environment:
  KYBER_TOKEN          KYBER token (sent as the authorization header)
  KYBER_EA_TOKEN       optional; used to log in if the KYBER token is rejected
  KYBER_SERVER_NAME    name used to find this server among the account's servers
  KYBER_API_HOST       default api-rpc.prod.kyber.gg
  KYBER_STATE_DIR      where the session token and server id are cached
"""
import json
import os
import struct
import subprocess
import sys
import tempfile
import zlib
import time
import uuid

HOST = os.environ.get("KYBER_API_HOST", "api-rpc.prod.kyber.gg")  # gRPC host (api.* is the HTTP API)
SESSION_ID = str(uuid.uuid4())
STATE_DIR = os.environ.get("KYBER_STATE_DIR", os.path.join(os.environ.get("HOME", "/tmp"), ".kyber-amp"))
STATE_FILE = os.path.join(STATE_DIR, "api-state.json")


class ApiError(Exception):
    pass


# ---------------------------------------------------------------- protobuf
def _varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def pb_str(field, value):
    data = value.encode("utf-8")
    return _varint((field << 3) | 2) + _varint(len(data)) + data


def pb_decode(buf):
    """Decode a message into {field: [values]}; length-delimited values stay bytes."""
    fields, i = {}, 0
    while i < len(buf):
        key, i = _read_varint(buf, i)
        field, wire = key >> 3, key & 7
        if wire == 0:
            val, i = _read_varint(buf, i)
        elif wire == 2:
            ln, i = _read_varint(buf, i)
            val, i = buf[i:i + ln], i + ln
        elif wire == 1:
            val, i = buf[i:i + 8], i + 8
        elif wire == 5:
            val, i = buf[i:i + 4], i + 4
        else:
            raise ApiError("unsupported protobuf wire type %d" % wire)
        fields.setdefault(field, []).append(val)
    return fields


def _read_varint(buf, i):
    shift = result = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def s(fields, n):
    v = fields.get(n)
    return v[0].decode("utf-8", "replace") if v else ""


# ---------------------------------------------------------------- transport
def call(method, payload=b"", auth=None):
    """Unary gRPC call, e.g. call('kyber_api.Authentication/Verify')."""
    frame = b"\x00" + struct.pack(">I", len(payload)) + payload
    with tempfile.TemporaryDirectory() as tmp:
        body_in, body_out, hdrs = (os.path.join(tmp, n) for n in ("in", "out", "hdr"))
        with open(body_in, "wb") as f:
            f.write(frame)
        cmd = [os.environ.get("KYBER_CURL", "curl"), "-sS", "--http2", "--max-time", "20", "-X", "POST",
               "-H", "content-type: application/grpc", "-H", "te: trailers",
               # Same metadata the KYBER launcher sends (Packages/kyber/.../api_service.dart).
               "-H", "x-session-id: " + SESSION_ID, "-H", "x-kv2-dsid: 53ff61a4-b751-40f6-a0c8-31d362f29936",
               "--data-binary", "@" + body_in, "-D", hdrs, "-o", body_out]
        if auth:
            # Passed through a config file so the token never appears in `ps`.
            cfg = os.path.join(tmp, "cfg")
            with open(cfg, "w") as f:
                f.write('header = "authorization: %s"\n' % auth.replace('"', ""))
            cmd += ["-K", cfg]
        cmd.append("https://%s/%s" % (HOST, method))
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise ApiError("connection to %s failed: %s" % (HOST, proc.stderr.strip()))
        headers = open(hdrs, encoding="latin-1").read()
        body = open(body_out, "rb").read()
    name = method.split("/")[-1]
    http_status, ctype, status, message = "", "", None, ""
    for line in headers.splitlines():
        low = line.lower()
        if low.startswith("http/"):
            parts = line.split()
            http_status = parts[1] if len(parts) > 1 else ""
        elif low.startswith("content-type:"):
            ctype = low.split(":", 1)[1].strip()
        elif low.startswith("grpc-status:"):
            status = line.split(":", 1)[1].strip()
        elif low.startswith("grpc-message:"):
            message = line.split(":", 1)[1].strip()
    if os.environ.get("KYBER_API_DEBUG"):
        sys.stderr.write("[kyber-api] %s -> HTTP %s, %s, grpc-status %s, %d body bytes, head %r\n"
                         % (name, http_status, ctype, status, len(body), body[:48]))
    if http_status != "200" or not ctype.startswith("application/grpc"):
        snippet = body[:160].decode("utf-8", "replace").strip().replace("\n", " ")
        raise ApiError("%s: unexpected reply (HTTP %s, %s) %s" % (name, http_status or "?", ctype or "no content-type", snippet))
    if status not in (None, "0"):
        raise ApiError("%s failed (grpc-status %s) %s" % (name, status, message))
    if len(body) < 5:
        return {}
    flag, ln = body[0], struct.unpack(">I", body[1:5])[0]
    data = body[5:5 + ln]
    if flag & 1:  # compressed message (gzip)
        data = zlib.decompress(data, 47)
    try:
        return pb_decode(data)
    except (ApiError, IndexError) as e:
        raise ApiError("%s: could not decode reply (%s) %r" % (name, e, body[:32]))


# ---------------------------------------------------------------- state / auth
def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, STATE_FILE)


def session(state):
    """Return (auth_token, user_id, user_name)."""
    candidates = []
    if state.get("session"):
        candidates.append(state["session"])
    kyber = os.environ.get("KYBER_TOKEN", "").strip()
    if kyber and kyber not in candidates:
        candidates.append(kyber)
    for tok in candidates:
        try:
            v = call("kyber_api.Authentication/Verify", auth=tok)
            state["session"] = tok
            return tok, s(v, 1), s(v, 2)
        except ApiError:
            continue
    ea = os.environ.get("KYBER_EA_TOKEN", "").strip()
    if ea:
        r = call("kyber_api.Authentication/Login", pb_str(1, ea))
        state["session"] = s(r, 2)
        return state["session"], s(r, 1), s(r, 3)
    raise ApiError("KYBER API login failed; check the KYBER token (and EA token) settings")


def my_servers(auth):
    servers, page = [], 1
    r = call("kyber_api.ServerManagement/ModeratedServers", auth=auth)
    for raw in r.get(3, []):
        f = pb_decode(raw)
        servers.append({"id": s(f, 1), "name": s(f, 2), "creatorId": s(f, 5)})
    return servers


def server_id(state, auth, user_id, wait=0):
    name = os.environ.get("KYBER_SERVER_NAME", "").strip()
    deadline = time.time() + wait
    while True:
        servers = my_servers(auth)
        mine = [x for x in servers if x["name"] == name and (not user_id or x["creatorId"] == user_id)] \
            or [x for x in servers if x["name"] == name]
        if mine:
            state["server_id"] = mine[0]["id"]
            return mine[0]["id"]
        if time.time() >= deadline:
            raise ApiError("server '%s' is not registered with KYBER (yet)" % name)
        time.sleep(10)


def resolve_user(auth, entry):
    entry = entry.strip()
    if entry.isdigit():
        return entry, entry
    r = call("kyber_api.Statistics/SearchUser", pb_str(1, entry), auth=auth)
    users = [pb_decode(u) for u in r.get(1, [])]
    exact = [u for u in users if s(u, 3).lower() == entry.lower()]
    if not exact:
        raise ApiError("no KYBER/EA user named '%s'" % entry)
    return s(exact[0], 1), s(exact[0], 3)


# ---------------------------------------------------------------- commands
def main(argv):
    if not argv:
        print(__doc__.strip())
        return 2
    if argv[0] == "probe":
        # Unauthenticated call that shows what the API endpoint answers with.
        os.environ["KYBER_API_DEBUG"] = "1"
        try:
            call("kyber_api.Authentication/Verify")
            print("probe: Verify answered without error")
        except ApiError as e:
            print("probe: %s" % e)
        return 0
    state = load_state()
    try:
        auth, uid, uname = session(state)
        cmd = argv[0]
        if cmd == "whoami":
            print("%s (%s)" % (uname, uid))
        elif cmd == "server-id":
            print(server_id(state, auth, uid, wait=int(os.environ.get("KYBER_WAIT", "0"))))
        elif cmd == "run":
            text = " ".join(argv[1:]).strip().lstrip("/")
            if not text:
                raise ApiError("no command given")
            sid = state.get("server_id") or server_id(state, auth, uid)
            try:
                call("kyber_api.ServerManagement/RunCommand", pb_str(1, sid) + pb_str(2, text), auth=auth)
            except ApiError:
                # The id changes when the server restarts; look it up again once.
                sid = server_id(state, auth, uid)
                call("kyber_api.ServerManagement/RunCommand", pb_str(1, sid) + pb_str(2, text), auth=auth)
            print("[KYBER] > %s" % text)
        elif cmd == "admins":
            sid = state.get("server_id") or server_id(state, auth, uid)
            r = call("kyber_api.ServerManagement/GetModerators", pb_str(1, sid), auth=auth)
            mods = [pb_decode(u) for u in r.get(1, [])]
            print("[KYBER] Admins: " + (", ".join("%s (%s)" % (s(m, 2), s(m, 1)) for m in mods) or "none"))
        elif cmd == "sync-admins":
            remove = "--remove-others" in argv
            wanted_entries = [a for a in argv[1:] if a != "--remove-others"]
            sid = server_id(state, auth, uid, wait=int(os.environ.get("KYBER_WAIT", "0")))
            r = call("kyber_api.ServerManagement/GetModerators", pb_str(1, sid), auth=auth)
            current = {s(f, 1): s(f, 2) for f in (pb_decode(u) for u in r.get(1, []))}
            wanted = {}
            for entry in wanted_entries:
                try:
                    uid_, name_ = resolve_user(auth, entry)
                    wanted[uid_] = name_
                except ApiError as e:
                    print("[KYBER] WARNING: admin '%s' skipped: %s" % (entry, e))
            for uid_, name_ in wanted.items():
                if uid_ in current:
                    continue
                call("kyber_api.ServerManagement/AddModerator", pb_str(1, uid_), auth=auth)
                print("[KYBER] Added admin %s (%s)" % (name_, uid_))
            if remove:
                for uid_, name_ in current.items():
                    if uid_ not in wanted:
                        call("kyber_api.ServerManagement/RemoveModerator", pb_str(1, uid_), auth=auth)
                        print("[KYBER] Removed admin %s (%s)" % (name_, uid_))
            print("[KYBER] Admins in sync (%d configured)." % len(wanted))
        else:
            raise ApiError("unknown command '%s'" % cmd)
        return 0
    except ApiError as e:
        print("[KYBER] ERROR: %s" % e)
        return 1
    finally:
        save_state(state)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
