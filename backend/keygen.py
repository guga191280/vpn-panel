import sqlite3, json

DB_PATH = '/opt/vpn_panel/backend/vpn_panel.db'

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def generate_keys(uuid):
    conn = get_db()
    hosts = conn.execute("SELECT * FROM hosts WHERE active=1").fetchall()
    nodes = {n["id"]: dict(n) for n in conn.execute("SELECT * FROM nodes WHERE status='online'").fetchall()}
    bridges = [dict(b) for b in conn.execute("SELECT * FROM bridges WHERE active=1").fetchall()]
    conn.close()

    keys = {}
    for h in hosts:
        tag = h["inbound_tag"]
        remark = h["remark"]
        address = h["address"]
        port = h["port"]
        sni = h["sni"] or ""

        if tag == "vless-in":
            is_bridge = remark.startswith("Bridge")
            if is_bridge:
                bridge = next((b for b in bridges if b["ru_ip"] == address), None)
                if bridge:
                    fn = next((n for n in nodes.values() if n["host"] == bridge["foreign_ip"]), None)
                    pbk = fn.get("public_key","") if fn else ""
                    sid = fn.get("short_id","") if fn else ""
                else:
                    pbk = sid = ""
            else:
                node = next((n for n in nodes.values() if n["host"] == address), None)
                if node:
                    pbk = node.get("public_key","") or ""
                    sid = node.get("short_id","") or ""
                    # Если пустые — читаем напрямую из sing-box конфига (для main ноды)
                    if not pbk and node.get("id") == "main":
                        try:
                            import json as _j
                            with open("/etc/sing-box/config.json") as _f:
                                _cfg = _j.load(_f)
                            for _inb in _cfg.get("inbounds", []):
                                _tls = _inb.get("tls", {})
                                _r = _tls.get("reality", {})
                                if _r.get("enabled"):
                                    # public_key нужно брать из БД, не из конфига (там private_key)
                                    from sqlite3 import connect as _conn
                                    _db = _conn('/opt/vpn_panel/backend/vpn_panel.db')
                                    _r2 = _db.execute("SELECT value FROM settings WHERE key='public_key'").fetchone()
                                    if _r2: pbk = _r2[0]
                                    else: pbk = _r.get("public_key", "")
                                    _sids = _r.get("short_id", [])
                                    sid = _sids[0] if _sids else ""
                                    break
                        except: pass
                else:
                    pbk = sid = ""
            if pbk and sid:
                key = (f"vless://{uuid}@{address}:{port}"
                      f"?encryption=none&flow=xtls-rprx-vision&security=reality"
                      f"&sni={sni}&fp=chrome&pbk={pbk}&sid={sid}"
                      f"&type=tcp&headerType=none#{remark}")
                keys[f"vless_{remark}"] = key

        elif tag == "vless-grpc-in":
            node = next((n for n in nodes.values() if n["host"] == address), None)
            if node:
                pbk = node.get("public_key","") or ""
                sid = node.get("short_id","") or ""
            else:
                pbk = sid = ""
            if pbk and sid:
                key = (f"vless://{uuid}@{address}:{port}"
                      f"?encryption=none&security=reality"
                      f"&sni={sni}&fp=chrome&pbk={pbk}&sid={sid}"
                      f"&type=grpc&serviceName=xyz&mode=gun#{remark}")
                keys[f"vless_grpc_{remark}"] = key
        elif tag == "vless-ws-in":
            key = (f"vless://{uuid}@{address}:{port}"
                  f"?encryption=none&security=none"
                  f"&type=ws&path=%2Fvless&host={sni}#{remark}")
            keys[f"vless_ws_{remark}"] = key
        elif tag == "hysteria2-in":
            key = f"hysteria2://{uuid}@{address}:{port}?sni={sni}&insecure=1#{remark}"
            keys[f"hy2_{remark}"] = key

    if keys:
        first_vless = next((v for k,v in keys.items() if "vless" in k), "")
        keys["vless_main"] = first_vless
        keys["vless"] = first_vless

    return keys

def generate_sub(uuid):
    keys = generate_keys(uuid)
    lines = [v for k,v in keys.items() if k not in ("vless_main","vless")]
    return "\n".join(lines)
