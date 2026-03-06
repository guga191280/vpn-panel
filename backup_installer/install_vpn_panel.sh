#!/bin/bash
echo '📦 Начинаю развертывание VPN Panel...'
mkdir -p /opt/vpn_panel/backend /opt/vpn_panel/frontend
echo '📄 Распаковка /opt/vpn_panel/backend/main.py...'
cat <<'FILEEOF' > /opt/vpn_panel/backend/main.py
from fastapi import FastAPI, HTTPException, Depends, Header, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from pydantic import BaseModel
from typing import Optional, List
import sqlite3, uuid, time, json, hashlib, secrets, asyncio, aiohttp
from datetime import datetime, timedelta
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import keygen
import os

app = FastAPI(title="VPN Panel API")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

DB_PATH = os.path.join(os.path.dirname(__file__), "vpn_panel.db")

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

# ===== AUDIT LOG =====
def audit_log(admin, action, details=""):
    try:
        conn = get_db()
        conn.execute(
            "INSERT INTO audit_log (admin, action, details, created_at) VALUES (?,?,?,?)",
            (admin, action, details, int(__import__('time').time()))
        )
        conn.commit()
        conn.close()
    except: pass

def init_db():
    conn = get_db()
    c = conn.cursor()
    c.execute("""CREATE TABLE IF NOT EXISTS admins (
        id INTEGER PRIMARY KEY, username TEXT UNIQUE, password_hash TEXT, token TEXT)""")
    c.execute("""CREATE TABLE IF NOT EXISTS nodes (
        id TEXT PRIMARY KEY, name TEXT, host TEXT, port INTEGER DEFAULT 22,
        api_port INTEGER DEFAULT 8000, api_token TEXT, country TEXT,
        protocols TEXT DEFAULT '[]', status TEXT DEFAULT 'offline',
        traffic_used INTEGER DEFAULT 0, created_at INTEGER)""")
    c.execute("""CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY, username TEXT UNIQUE, telegram_id TEXT,
        status TEXT DEFAULT 'active', data_limit INTEGER DEFAULT 0,
        data_used INTEGER DEFAULT 0, expire_at INTEGER DEFAULT 0,
        subscription_url TEXT, node_ids TEXT DEFAULT '[]',
        created_at INTEGER, note TEXT DEFAULT '')""")
    pwd_hash = hashlib.sha256("admin123".encode()).hexdigest()
    c.execute("INSERT OR IGNORE INTO admins (username, password_hash, token) VALUES (?, ?, ?)",
              ("admin", pwd_hash, secrets.token_hex(32)))
    conn.commit(); conn.close()

init_db()
security = HTTPBearer()

def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)):
    conn = get_db()
    admin = conn.execute("SELECT * FROM admins WHERE token = ?", (credentials.credentials,)).fetchone()
    conn.close()
    if not admin: raise HTTPException(status_code=401, detail="Invalid token")
    return dict(admin)

class LoginRequest(BaseModel):
    username: str
    password: str



class NodeUpdate(BaseModel):
    name: str = None
    host: str = None
    country: str = None
    status: str = None

class UserCreate(BaseModel):
    username: str
    telegram_id: str = None
    data_limit_mb: float = 0
    expire_days: int = 0
    node_ids: list = []
    note: str = ""

class UserUpdate(BaseModel):
    status: str = None
    data_limit_mb: float = None
    expire_days: int = None
    note: str = None

class NodeCreate(BaseModel):
    name: str
    host: str
    country: str = "Unknown"
    api_port: int = 9090
    api_token: str = ""
    protocols: list = ["vless", "hysteria2"]
    ssh_port: int = 22
    ssh_user: str = "root"
    ssh_password: str = ""
    auto_install: bool = False

@app.get("/api/nodes")
def get_nodes(admin=Depends(verify_token)):
    conn = get_db()
    nodes = conn.execute("SELECT * FROM nodes ORDER BY created_at DESC").fetchall()
    conn.close()
    return [{**{k: v for k, v in dict(n).items() if k != "protocols"}, "protocols": json.loads(n["protocols"])} for n in nodes]

@app.post("/api/nodes")
def create_node(node: NodeCreate, admin=Depends(verify_token)):
    import subprocess as sp
    conn = get_db()
    node_id = str(uuid.uuid4())[:8]
    
    # Если запрошена автоустановка — запускаем в фоне
    if node.auto_install and node.ssh_password:
        conn.execute("INSERT INTO nodes (id,name,host,port,api_port,api_token,country,protocols,status,created_at,ssh_user,ssh_password) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                     (node_id, node.name, node.host, node.ssh_port, node.api_port, node.api_token, node.country, json.dumps(node.protocols), "installing", int(time.time()), node.ssh_user, node.ssh_password))
        conn.commit(); conn.close()
        # Запускаем установку в фоне
        sp.Popen(["/opt/vpn_panel/venv/bin/python3", "/opt/vpn_panel/backend/auto_install_node.py",
                  node_id, node.host, str(node.ssh_port), node.ssh_user, node.ssh_password,
                  node.name, node.country])
        # Хосты создаются в auto_install_node.py с правильными портами
        pass
        return {"success": True, "id": node_id, "status": "installing"}
    else:
        conn.execute("INSERT INTO nodes (id,name,host,port,api_port,api_token,country,protocols,status,created_at,ssh_user,ssh_password) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                     (node_id, node.name, node.host, node.ssh_port, node.api_port, node.api_token, node.country, json.dumps(node.protocols), "offline", int(time.time()), node.ssh_user, node.ssh_password))
        # Автоматически создаём hosts для ноды
        try:
            conn.execute("INSERT INTO hosts (inbound_tag, remark, address, port, sni, active) VALUES (?,?,?,?,?,1)",
                ('vless-in', node.name+' VLESS', node.host, 443, 'www.microsoft.com'))
            conn.execute("INSERT INTO hosts (inbound_tag, remark, address, port, sni, active) VALUES (?,?,?,?,?,1)",
                ('hysteria2-in', node.name+' HY2', node.host, 20897, node.host))
        except: pass
        conn.commit()
        # Проверяем доступность
        try:
            import urllib.request as _ur
            _ur.urlopen(f'http://{node.host}:{node.api_port}/version', timeout=3)
            conn.execute("UPDATE nodes SET status='online' WHERE id=?", (node_id,))
            conn.commit()
        except: pass
        conn.close()
        return {"success": True, "id": node_id}
@app.put("/api/nodes/{node_id}")
def update_node(node_id: str, node: NodeUpdate, admin=Depends(verify_token)):
    conn = get_db()
    updates = {}
    if node.name: updates["name"] = node.name
    if node.host: updates["host"] = node.host
    if node.api_port: updates["api_port"] = node.api_port
    if node.api_token is not None: updates["api_token"] = node.api_token
    if node.country: updates["country"] = node.country
    if node.protocols: updates["protocols"] = json.dumps(node.protocols)
    if updates:
        set_clause = ", ".join([f"{k} = ?" for k in updates])
        conn.execute(f"UPDATE nodes SET {set_clause} WHERE id = ?", list(updates.values()) + [node_id])
        conn.commit()
    conn.close()
    return {"success": True}

@app.delete("/api/nodes/{node_id}")
def delete_node(node_id: str, admin=Depends(verify_token)):
    conn = get_db()
    conn.execute("DELETE FROM nodes WHERE id = ?", (node_id,))
    conn.commit(); conn.close()
    return {"success": True}

@app.get("/api/nodes/{node_id}/ping")
async def ping_node(node_id: str, admin=Depends(verify_token)):
    conn = get_db()
    node = conn.execute("SELECT * FROM nodes WHERE id = ?", (node_id,)).fetchone()
    conn.close()
    if not node: raise HTTPException(status_code=404)
    node = dict(node)
    # Bridge нода - всегда online
    if node.get('country') in ['Russia','russia'] or node_id in ['ru75','main'] or node.get('host','').startswith('185.40') or node.get('host','').startswith('ru75'):
        conn2 = get_db()
        conn2.execute("UPDATE nodes SET status='online' WHERE id=?", (node_id,))
        conn2.commit()
        conn2.close()
        return {"status": "online", "node_id": node_id}
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(f"http://{node['host']}:{node['api_port']}/health", timeout=aiohttp.ClientTimeout(total=5)) as resp:
                online = resp.status == 200
    except: online = False
    status = "online" if online else "offline"
    db = get_db(); db.execute("UPDATE nodes SET status = ? WHERE id = ?", (status, node_id)); db.commit(); db.close()
    return {"status": status}

class UserCreate(BaseModel):
    username: str; telegram_id: Optional[str] = None
    data_limit_mb: float = 0; expire_days: int = 0
    node_ids: List[str] = []; note: str = ""

class UserUpdate(BaseModel):
    status: Optional[str] = None; data_limit_mb: Optional[float] = None
    expire_days: Optional[int] = None; node_ids: Optional[List[str]] = None
    note: Optional[str] = None

@app.get("/api/users")
def get_users(admin=Depends(verify_token)):
    conn = get_db()
    users = conn.execute("SELECT * FROM users ORDER BY created_at DESC").fetchall()
    conn.close()
    result = []
    for u in users:
        d = dict(u)
        d["node_ids"] = json.loads(d.get("node_ids") or "[]")
        result.append(d)
    return result

@app.post("/api/users")
def create_user(user: UserCreate, admin=Depends(verify_token)):
    conn = get_db()
    if conn.execute("SELECT id FROM users WHERE username = ?", (user.username,)).fetchone():
        raise HTTPException(status_code=409, detail="Username exists")
    user_id = str(uuid.uuid4())
    data_limit = int(user.data_limit_mb * 1024**2)
    expire_at = int((datetime.now() + timedelta(days=user.expire_days)).timestamp()) if user.expire_days > 0 else 0
    keys = keygen.generate_keys(user_id)
    sub_url = keys.get("vless_main", keys.get("vless", ""))
    hy2_url = keys.get("hy2_main", keys.get("hysteria2", ""))
    vless_ru75 = keys.get("vless_fin", keys.get("vless_ru75", ""))
    hy2_ru75 = keys.get("hy2_fin", keys.get("hy2_ru75", ""))
    # Собираем все bridge ключи
    bridge_keys = {k:v for k,v in keys.items() if 'bridge' in k}
    vless_bridge = next((v for k,v in bridge_keys.items() if 'vless' in k), '')
    hy2_bridge = next((v for k,v in bridge_keys.items() if 'hy2' in k), '')
    import secrets as _s
    sub_tok = _s.token_urlsafe(24)
    conn.execute("""INSERT INTO users 
        (id,username,telegram_id,status,data_limit,expire_at,
         subscription_url,hysteria2_url,vless_ru75,hy2_ru75,
         vless_main_bridge,hy2_main_bridge,node_ids,created_at,note,sub_token) 
        VALUES (?,?,?,'active',?,?,?,?,?,?,?,?,?,?,?,?)""",
        (user_id, user.username, user.telegram_id, data_limit, expire_at,
         sub_url, hy2_url, vless_ru75, hy2_ru75,
         vless_bridge, hy2_bridge,
         json.dumps(user.node_ids), int(time.time()), user.note, sub_tok))

    conn.commit(); conn.close()
    # Синхронизируем с Sing-box
    import subprocess
    subprocess.Popen(["/opt/vpn_panel/venv/bin/python3", "/opt/vpn_panel/backend/sync_users.py"])
    audit_log("admin", "Создан пользователь", f"username: {user.username}")
    return {
        "success": True, 
        "id": user_id, 
        "subscription_url": sub_url,
        "hysteria2_url": hy2_url,
        "vless_main": keys.get("vless_main", sub_url),
        "hy2_main": keys.get("hy2_main", hy2_url),
        "vless_fin": keys.get("vless_fin", ""),
        "hy2_fin": keys.get("hy2_fin", ""),
        "vless_ru75": keys.get("vless_fin", ""),
        "hy2_ru75": keys.get("hy2_fin", ""),
        "all_keys": json.dumps(keys)
    }

@app.put("/api/users/{user_id}")
def update_user(user_id: str, user: UserUpdate, admin=Depends(verify_token)):
    conn = get_db()
    updates = {}
    if user.status: updates["status"] = user.status
    if user.data_limit_mb is not None: updates["data_limit"] = int(user.data_limit_mb * 1024**2)
    if user.expire_days is not None: updates["expire_at"] = int((datetime.now() + timedelta(days=user.expire_days)).timestamp())
    if user.node_ids is not None: updates["node_ids"] = json.dumps(user.node_ids)
    if user.note is not None: updates["note"] = user.note
    if updates:
        set_clause = ", ".join([f"{k} = ?" for k in updates])
        conn.execute(f"UPDATE users SET {set_clause} WHERE id = ?", list(updates.values()) + [user_id])
        conn.commit()
    conn.close()
    return {"success": True}

@app.delete("/api/users/{user_id}")
def delete_user(user_id: str, admin=Depends(verify_token)):
    conn = get_db()
    u = conn.execute("SELECT username FROM users WHERE id=?", (user_id,)).fetchone()
    conn.execute("DELETE FROM users WHERE id = ?", (user_id,))
    conn.commit(); conn.close()
    import subprocess
    subprocess.Popen(["/opt/vpn_panel/venv/bin/python3", "/opt/vpn_panel/backend/sync_users.py"])
    if u: audit_log("admin", "Удалён пользователь", f"username: {u['username']}")
    return {"success": True}


@app.get("/api/connections/count")
def connections_count(admin=Depends(verify_token)):
    try:
        import requests as req
        r = req.get("http://127.0.0.1:9090/connections", timeout=3)
        if r.status_code == 200:
            conns = r.json().get("connections", [])
            # Уникальные IP = уникальные пользователи
            ips = set(c.get("metadata",{}).get("sourceIP","") for c in conns)
            ips.discard("")
            return {"count": len(conns), "unique_users": len(ips)}
    except: pass
    return {"count": 0, "unique_users": 0}

@app.get("/api/stats")
def get_stats(admin=Depends(verify_token)):
    conn = get_db()
    total_users = conn.execute("SELECT COUNT(*) FROM users").fetchone()[0]
    active_users = conn.execute("SELECT COUNT(*) FROM users WHERE status='active'").fetchone()[0]
    total_nodes = conn.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
    online_nodes = conn.execute("SELECT COUNT(*) FROM nodes WHERE status='online'").fetchone()[0]
    total_traffic = conn.execute("SELECT SUM(data_used) FROM users").fetchone()[0] or 0
    conn.close()
    return {"total_users": total_users, "active_users": active_users,
            "total_nodes": total_nodes, "online_nodes": online_nodes,
            "total_traffic_gb": round(total_traffic / 1024**3, 2)}

FRONTEND_DIR = os.path.join(os.path.dirname(__file__), "..", "frontend")
app.mount("/static", StaticFiles(directory=FRONTEND_DIR), name="static")

@app.get("/")
def serve_frontend():
    return FileResponse(os.path.join(FRONTEND_DIR, "index.html"))


class BridgeCreate(BaseModel):
    node_id: str
    ru_ip: str
    foreign_ip: str
    ssh_port: int = 22
    ssh_user: str = "root"
    ssh_password: str = ""
    foreign_ssh_port: int = 22
    foreign_ssh_user: str = "root"
    foreign_ssh_password: str = ""

@app.get("/api/bridges")
def get_bridges(admin=Depends(verify_token)):
    conn = get_db()
    bridges = conn.execute("SELECT * FROM bridges WHERE active=1").fetchall()
    conn.close()
    return [dict(b) for b in bridges]

@app.post("/api/bridges")
def create_bridge(bridge: BridgeCreate, admin=Depends(verify_token)):
    import subprocess, time as t
    conn = get_db()
    conn.execute("INSERT INTO bridges (node_id,ru_ip,foreign_ip,active,created_at) VALUES (?,?,?,1,?)",
                 (bridge.node_id, bridge.ru_ip, bridge.foreign_ip, int(t.time())))
    conn.commit()
    conn.close()
    if bridge.ssh_password:
        subprocess.Popen(["python3","/opt/vpn_panel/backend/auto_bridge.py",
                          bridge.node_id, bridge.ru_ip, str(bridge.ssh_port),
                          bridge.ssh_user, bridge.ssh_password, bridge.foreign_ip,
                          str(bridge.foreign_ssh_port), bridge.foreign_ssh_user,
                          bridge.foreign_ssh_password])
    else:
        subprocess.Popen(["python3","/opt/vpn_panel/backend/setup_bridge.py",
                          bridge.node_id, bridge.ru_ip, bridge.foreign_ip])
    return {"success": True}

@app.delete("/api/bridges/{bridge_id}")
def delete_bridge(bridge_id: int, admin=Depends(verify_token)):
    conn = get_db()
    conn.execute("UPDATE bridges SET active=0 WHERE id=?", (bridge_id,))
    conn.commit()
    conn.close()
    return {"success": True}


import threading

def check_nodes_status():
    """Периодически проверяет статус нод"""
    import requests
    while True:
        try:
            conn = get_db()
            nodes = conn.execute("SELECT id, host, api_port, api_token FROM nodes WHERE status != 'installing'").fetchall()
            conn.close()
            for node in nodes:
                nid, host, api_port, token = node
                try:
                    r = requests.get(f"http://{host}:{api_port}", timeout=5)
                    status = 'online' if r.status_code in [200, 401] else 'offline'
                except:
                    status = 'offline'
                conn2 = get_db()
                conn2.execute("UPDATE nodes SET status=? WHERE id=?", (status, nid))
                conn2.commit()
                conn2.close()
        except:
            pass
        import time as t
        t.sleep(30)

# Запускаем проверку в фоне
_checker = threading.Thread(target=check_nodes_status, daemon=True)
_checker.start()


import hashlib, secrets

# ============= SUBADMINS =============

class SubAdminCreate(BaseModel):
    username: str
    password: str
    can_add_users: bool = True
    can_delete_users: bool = True
    can_toggle_users: bool = True
    can_view_keys: bool = True
    can_manage_nodes: bool = False
    can_manage_bridges: bool = False

def verify_any_token(token: str = Header(None, alias="Authorization")):
    """Проверяет токен главного админа или субадмина"""
    if not token:
        raise HTTPException(status_code=401)
    token = token.replace("Bearer ", "")
    conn = get_db()
    # Сначала проверяем главного админа
    admin = conn.execute("SELECT * FROM admins WHERE token=?", (token,)).fetchone()
    if admin:
        conn.close()
        return {"role": "admin", "username": admin["username"], "permissions": "all"}
    # Потом субадмина
    sub = conn.execute("SELECT * FROM subadmins WHERE token=?", (token,)).fetchone()
    conn.close()
    if sub:
        return {"role": "subadmin", "username": sub["username"], 
                "can_add_users": sub["can_add_users"],
                "can_delete_users": sub["can_delete_users"],
                "can_toggle_users": sub["can_toggle_users"],
                "can_view_keys": sub["can_view_keys"],
                "can_manage_nodes": sub["can_manage_nodes"],
                "can_manage_bridges": sub["can_manage_bridges"]}
    raise HTTPException(status_code=401)

@app.post("/api/login")
def login(creds: dict):
    conn = get_db()
    pwd_hash = hashlib.sha256(creds["password"].encode()).hexdigest()
    # Главный админ
    admin = conn.execute("SELECT * FROM admins WHERE username=? AND password_hash=?",
                        (creds["username"], pwd_hash)).fetchone()
    if admin:
        token = secrets.token_hex(32)
        conn.execute("UPDATE admins SET token=? WHERE id=?", (token, admin["id"]))
        conn.commit(); conn.close()
        audit_log(admin["username"], "Вход в систему")
        return {"token": token, "username": admin["username"], "role": "admin"}
    # Субадмин
    sub = conn.execute("SELECT * FROM subadmins WHERE username=? AND password_hash=?",
                      (creds["username"], pwd_hash)).fetchone()
    if sub:
        token = secrets.token_hex(32)
        conn.execute("UPDATE subadmins SET token=? WHERE id=?", (token, sub["id"]))
        conn.commit(); conn.close()
        return {"token": token, "username": sub["username"], "role": "subadmin",
                "can_add_users": bool(sub["can_add_users"]),
                "can_delete_users": bool(sub["can_delete_users"]),
                "can_toggle_users": bool(sub["can_toggle_users"]),
                "can_view_keys": bool(sub["can_view_keys"]),
                "can_manage_nodes": bool(sub["can_manage_nodes"]),
                "can_manage_bridges": bool(sub["can_manage_bridges"])}
    conn.close()
    raise HTTPException(status_code=401, detail="Invalid credentials")

@app.get("/api/subadmins")
def get_subadmins(admin=Depends(verify_token)):
    conn = get_db()
    subs = conn.execute("SELECT id,username,can_add_users,can_delete_users,can_toggle_users,can_view_keys,can_manage_nodes,can_manage_bridges,created_at FROM subadmins").fetchall()
    conn.close()
    return [dict(s) for s in subs]

@app.post("/api/subadmins")
def create_subadmin(sub: SubAdminCreate, admin=Depends(verify_token)):
    import time as t
    conn = get_db()
    pwd_hash = hashlib.sha256(sub.password.encode()).hexdigest()
    try:
        conn.execute("""INSERT INTO subadmins 
            (username,password_hash,can_add_users,can_delete_users,can_toggle_users,
             can_view_keys,can_manage_nodes,can_manage_bridges,created_at)
            VALUES (?,?,?,?,?,?,?,?,?)""",
            (sub.username, pwd_hash, int(sub.can_add_users), int(sub.can_delete_users),
             int(sub.can_toggle_users), int(sub.can_view_keys),
             int(sub.can_manage_nodes), int(sub.can_manage_bridges), int(t.time())))
        conn.commit(); conn.close()
        return {"success": True}
    except Exception as e:
        conn.close()
        raise HTTPException(status_code=400, detail=str(e))

@app.delete("/api/subadmins/{sub_id}")
def delete_subadmin(sub_id: int, admin=Depends(verify_token)):
    conn = get_db()
    conn.execute("DELETE FROM subadmins WHERE id=?", (sub_id,))
    conn.commit(); conn.close()
    return {"success": True}


# ============= BOT API =============

class BotCreate(BaseModel):
    name: str

@app.get("/api/bots")
def get_bots(admin=Depends(verify_token)):
    conn = get_db()
    bots = conn.execute("SELECT * FROM bots").fetchall()
    conn.close()
    return [dict(b) for b in bots]

@app.post("/api/bots")
def create_bot(bot: BotCreate, admin=Depends(verify_token)):
    import time as t, secrets
    conn = get_db()
    bot_token = "bot_" + secrets.token_hex(16)
    conn.execute("INSERT INTO bots (name, token, created_at) VALUES (?,?,?)",
                 (bot.name, bot_token, int(t.time())))
    conn.commit(); conn.close()
    return {"success": True, "token": bot_token}

@app.delete("/api/bots/{bot_id}")
def delete_bot(bot_id: int, admin=Depends(verify_token)):
    conn = get_db()
    conn.execute("DELETE FROM bots WHERE id=?", (bot_id,))
    conn.commit(); conn.close()
    return {"success": True}

# Публичный API для ботов (без авторизации админа)
def verify_bot_token(x_bot_token: str = Header(None)):
    if not x_bot_token:
        raise HTTPException(status_code=401, detail="Bot token required")
    conn = get_db()
    bot = conn.execute("SELECT * FROM bots WHERE token=?", (x_bot_token,)).fetchone()
    conn.close()
    if not bot:
        raise HTTPException(status_code=401, detail="Invalid bot token")
    return dict(bot)

@app.post("/bot/users/create")
def bot_create_user(data: dict, bot=Depends(verify_bot_token)):
    """Создать пользователя и получить ключи"""
    import uuid as uuid_lib, time as t, sys, json
    sys.path.insert(0, "/opt/vpn_panel/backend")
    import keygen
    
    username = data.get("username", "").strip()
    telegram_id = str(data.get("telegram_id", ""))
    expire_days = int(data.get("expire_days", 30))
    data_limit_mb = float(data.get("data_limit_mb", 0))
    
    if not username:
        raise HTTPException(status_code=400, detail="username required")
    
    user_id = str(uuid_lib.uuid4())
    expire_at = int(t.time()) + expire_days * 86400 if expire_days > 0 else 0
    data_limit = int(data_limit_mb * 1024**2)
    
    keys = keygen.generate_keys(user_id)
    sub_url = keys.get("vless_main", "")
    hy2_url = keys.get("hy2_main", "")
    
    conn = get_db()
    try:
        conn.execute("""INSERT INTO users 
            (id,username,telegram_id,status,data_limit,expire_at,
             subscription_url,hysteria2_url,vless_ru75,hy2_ru75,
             vless_main_bridge,hy2_main_bridge,node_ids,created_at,note)
            VALUES (?,?,?,'active',?,?,?,?,?,?,?,?,?,?,?)""",
            (user_id, username, telegram_id, data_limit, expire_at,
             sub_url, hy2_url,
             keys.get("vless_ru75",""), keys.get("hy2_ru75",""),
             keys.get("vless_main_bridge",""), keys.get("hy2_main_bridge",""),
             json.dumps([]), int(t.time()), ""))
        conn.commit()
    except Exception as e:
        conn.close()
        raise HTTPException(status_code=400, detail=str(e))
    conn.close()
    
    # Синхронизируем
    import subprocess
    subprocess.Popen(["/opt/vpn_panel/venv/bin/python3", "/opt/vpn_panel/backend/sync_users.py"])
    
    return {
        "success": True,
        "user_id": user_id,
        "username": username,
        "keys": {
            "vless_main": sub_url,
            "hy2_main": hy2_url,
            "vless_ru75": keys.get("vless_ru75",""),
            "hy2_ru75": keys.get("hy2_ru75",""),
            "vless_bridge": keys.get("vless_main_bridge",""),
            "hy2_bridge": keys.get("hy2_main_bridge",""),
            "all": keys.get("all","")
        },
        "expire_at": expire_at,
        "expire_days": expire_days
    }

@app.get("/bot/users/{telegram_id}")
def bot_get_user(telegram_id: str, bot=Depends(verify_bot_token)):
    """Получить ключи пользователя по Telegram ID"""
    conn = get_db()
    user = conn.execute("SELECT * FROM users WHERE telegram_id=?", (telegram_id,)).fetchone()
    conn.close()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    u = dict(user)
    return {
        "success": True,
        "user_id": u["id"],
        "username": u["username"],
        "status": u["status"],
        "keys": {
            "vless_main": u.get("subscription_url",""),
            "hy2_main": u.get("hysteria2_url",""),
            "vless_ru75": u.get("vless_ru75",""),
            "hy2_ru75": u.get("hy2_ru75",""),
            "vless_bridge": u.get("vless_main_bridge",""),
            "hy2_bridge": u.get("hy2_main_bridge","")
        },
        "expire_at": u.get("expire_at",0),
        "data_limit": u.get("data_limit",0),
        "data_used": u.get("data_used",0)
    }

@app.post("/bot/users/{telegram_id}/disable")
def bot_disable_user(telegram_id: str, bot=Depends(verify_bot_token)):
    """Отключить пользователя"""
    conn = get_db()
    conn.execute("UPDATE users SET status='disabled' WHERE telegram_id=?", (telegram_id,))
    conn.commit(); conn.close()
    return {"success": True}

@app.post("/bot/users/{telegram_id}/enable")
def bot_enable_user(telegram_id: str, bot=Depends(verify_bot_token)):
    """Включить пользователя"""
    conn = get_db()
    conn.execute("UPDATE users SET status='active' WHERE telegram_id=?", (telegram_id,))
    conn.commit(); conn.close()
    return {"success": True}


# Запускаем мониторинг трафика
def _start_traffic_monitor():
    import sys, threading
    sys.path.insert(0, '/opt/vpn_panel/backend')
    from traffic_monitor import monitor_loop
    t = threading.Thread(target=monitor_loop, daemon=True)
    t.start()

_start_traffic_monitor()


# ============= TRAFFIC API =============

@app.get("/api/traffic/stats")
def get_traffic_stats(admin=Depends(verify_token)):
    conn = get_db()
    users = conn.execute("SELECT username, data_used, data_limit, status, expire_at FROM users ORDER BY data_used DESC").fetchall()
    total = conn.execute("SELECT SUM(data_used) FROM users").fetchone()[0] or 0
    active = conn.execute("SELECT COUNT(*) FROM users WHERE status='active'").fetchone()[0]
    expired = conn.execute("SELECT COUNT(*) FROM users WHERE status='expired'").fetchone()[0]
    overlimit = conn.execute("SELECT COUNT(*) FROM users WHERE status='overlimit'").fetchone()[0]
    
    # Трафик по нодам
    node_rows = conn.execute("""
        SELECT nt.node_id, nt.bytes_up, nt.bytes_down, nt.updated_at, n.name, n.country
        FROM node_traffic nt
        LEFT JOIN nodes n ON n.id = nt.node_id
    """).fetchall()
    conn.close()
    
    nodes_traffic = []
    for nr in node_rows:
        total_bytes = (nr["bytes_up"] or 0) + (nr["bytes_down"] or 0)
        nodes_traffic.append({
            "node_id": nr["node_id"],
            "name": nr["name"] or nr["node_id"],
            "country": nr["country"] or "",
            "bytes_up": nr["bytes_up"] or 0,
            "bytes_down": nr["bytes_down"] or 0,
            "total_mb": round(total_bytes / 1048576, 1),
            "total_gb": round(total_bytes / 1073741824, 2),
            "updated_at": nr["updated_at"]
        })
    
    return {
        "total_traffic_bytes": total,
        "total_traffic_gb": round(total / 1073741824, 2),
        "total_traffic_mb": round(total / 1048576, 1),
        "active_users": active,
        "expired_users": expired,
        "overlimit_users": overlimit,
        "nodes": nodes_traffic,
        "users": [{
            "username": u["username"],
            "data_used_gb": round((u["data_used"] or 0) / 1073741824, 3),
            "data_used_mb": round((u["data_used"] or 0) / 1048576, 1),
            "data_limit_gb": round((u["data_limit"] or 0) / 1073741824, 1) if u["data_limit"] else 0,
            "status": u["status"],
            "expire_at": u["expire_at"]
        } for u in users]
    }


# ============= HOSTS =============
class HostUpdate(BaseModel):
    remark: str = None
    address: str = None
    port: int = None
    sni: str = None
    active: int = None

@app.get("/api/hosts")
def get_hosts(admin=Depends(verify_token)):
    conn = get_db()
    hosts = conn.execute("SELECT * FROM hosts").fetchall()
    conn.close()
    return [dict(h) for h in hosts]

@app.put("/api/hosts/{host_id}")
def update_host(host_id: int, data: HostUpdate, admin=Depends(verify_token)):
    conn = get_db()
    fields = {k:v for k,v in data.dict().items() if v is not None}
    for field, value in fields.items():
        conn.execute(f"UPDATE hosts SET {field}=? WHERE id=?", (value, host_id))
    conn.commit()
    conn.close()
    # Перегенерируем все ключи
    import subprocess
    subprocess.Popen(["python3", "/opt/vpn_panel/backend/regen_all_keys.py"])
    return {"success": True}

@app.post("/api/hosts")
def create_host(data: dict, admin=Depends(verify_token)):
    import time as t
    conn = get_db()
    conn.execute("INSERT INTO hosts (inbound_tag,remark,address,port,sni,active) VALUES (?,?,?,?,?,1)",
                 (data.get('inbound_tag',''), data.get('remark',''), 
                  data.get('address',''), int(data.get('port',443)),
                  data.get('sni','')))
    conn.commit()
    conn.close()
    return {"success": True}

@app.delete("/api/hosts/{host_id}")
def delete_host(host_id: int, admin=Depends(verify_token)):
    conn = get_db()
    conn.execute("DELETE FROM hosts WHERE id=?", (host_id,))
    conn.commit()
    conn.close()
    return {"success": True}


@app.post("/api/hosts/regen")
def regen_keys(admin=Depends(verify_token)):
    import subprocess
    subprocess.Popen(["python3", "/opt/vpn_panel/backend/regen_all_keys.py"])
    return {"success": True}


import secrets as _secrets
import psutil

# ============= SUBSCRIPTION =============
@app.get("/sub/{sub_token}")
def get_subscription(sub_token: str, request: Request):
    conn = get_db()
    user = conn.execute("SELECT * FROM users WHERE sub_token=?", (sub_token,)).fetchone()
    if not user:
        conn.close()
        raise HTTPException(status_code=404)
    
    # Динамически генерируем ключи через keygen
    user_uuid = user['id']
    # Получаем UUID из subscription_url если есть
    if user['subscription_url'] and 'vless://' in user['subscription_url']:
        import re as _re
        m = _re.search(r'vless://([^@]+)@', user['subscription_url'])
        if m: user_uuid = m.group(1)
    sub_content = keygen.generate_sub(user_uuid)
    keys = [l for l in sub_content.split('\n') if l.strip()]
    
    conn.close()
    sub_content = "\n".join(keys)
    import base64
    encoded = base64.b64encode(sub_content.encode()).decode()
    
    from fastapi.responses import Response
    return Response(
        content=encoded,
        media_type="text/plain",
        headers={
            "Content-Disposition": f"attachment; filename=sub.txt",
            "profile-title": f"base64:{base64.b64encode(user['username'].encode()).decode()}",
            "subscription-userinfo": f"upload=0; download={user['data_used'] or 0}; total={user['data_limit'] or 0}; expire={user['expire_at'] or 0}",
            "profile-update-interval": "12",
        }
    )

# ============= SETTINGS =============
@app.get("/api/settings")
def get_settings(admin=Depends(verify_token)):
    conn = get_db()
    rows = conn.execute("SELECT key, value FROM settings").fetchall()
    conn.close()
    return {r["key"]: r["value"] for r in rows}

@app.put("/api/settings")
def update_settings(data: dict, admin=Depends(verify_token)):
    conn = get_db()
    for k, v in data.items():
        conn.execute("INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)", (k, str(v)))
    conn.commit()
    conn.close()
    return {"success": True}

# ============= SYSTEM STATS =============
@app.get("/api/system/stats")
def get_system_stats(admin=Depends(verify_token)):
    cpu = psutil.cpu_percent(interval=1)
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    net = psutil.net_io_counters()
    return {
        "cpu_percent": cpu,
        "ram_total_gb": round(mem.total/1073741824, 1),
        "ram_used_gb": round(mem.used/1073741824, 1),
        "ram_percent": mem.percent,
        "disk_total_gb": round(disk.total/1073741824, 1),
        "disk_used_gb": round(disk.used/1073741824, 1),
        "disk_percent": disk.percent,
        "net_sent_gb": round(net.bytes_sent/1073741824, 2),
        "net_recv_gb": round(net.bytes_recv/1073741824, 2),
        "uptime_seconds": int(__import__("time").time() - psutil.boot_time())
    }

# ============= EXTEND SUBSCRIPTION =============
@app.post("/api/users/{user_id}/extend")
def extend_user(user_id: str, data: dict, admin=Depends(verify_token)):
    import time as _t
    days = int(data.get("days", 30))
    conn = get_db()
    user = conn.execute("SELECT expire_at FROM users WHERE id=?", (user_id,)).fetchone()
    if not user:
        conn.close()
        raise HTTPException(status_code=404)
    now = int(_t.time())
    current = user["expire_at"] or now
    new_expire = max(current, now) + days * 86400
    conn.execute("UPDATE users SET expire_at=?, status='active' WHERE id=?", (new_expire, user_id))
    conn.commit()
    conn.close()
    return {"success": True, "new_expire_at": new_expire}

# ============= USER SUB TOKEN =============
@app.post("/api/users/{user_id}/reset-sub")
def reset_sub_token(user_id: str, admin=Depends(verify_token)):
    token = _secrets.token_urlsafe(24)
    conn = get_db()
    conn.execute("UPDATE users SET sub_token=? WHERE id=?", (token, user_id))
    conn.commit()
    conn.close()
    return {"sub_token": token}

# ============= ONLINE CONNECTIONS =============
@app.get("/api/system/connections")
def get_connections(admin=Depends(verify_token)):
    try:
        import requests as _req
        r = _req.get("http://127.0.0.1:9090/connections",
                    headers={"Authorization": "Bearer vpnpanel2024"}, timeout=3)
        conns = r.json().get("connections", [])
        return {"total": len(conns), "connections": conns[:20]}
    except:
        return {"total": 0, "connections": []}


@app.post("/api/system/notify-test")
def test_notify(admin=Depends(verify_token)):
    import sys
    sys.path.insert(0, '/opt/vpn_panel/backend')
    try:
        from tg_notify import send_tg
        send_tg("✅ <b>Тест уведомления</b>\n\nПанель работает нормально.")
        return {"success": True}
    except Exception as e:
        return {"success": False, "error": str(e)}

import secrets as _sec, psutil, sys as _sys

# ===== SUBSCRIPTION =====
@app.get("/sub/{token}")
def subscription(token: str):
    import base64
    from fastapi.responses import Response
    conn = get_db()
    u = conn.execute("SELECT * FROM users WHERE sub_token=?", (token,)).fetchone()
    conn.close()
    if not u: raise HTTPException(404)
    keys = [u[f] for f in ['subscription_url','hysteria2_url','vless_ru75','hy2_ru75','vless_main_bridge','hy2_main_bridge'] if u[f]]
    encoded = base64.b64encode("\n".join(keys).encode()).decode()
    return Response(content=encoded, media_type="text/plain", headers={
        "profile-title": "base64:"+base64.b64encode(u["username"].encode()).decode(),
        "subscription-userinfo": f"upload=0; download={u['data_used'] or 0}; total={u['data_limit'] or 0}; expire={u['expire_at'] or 0}",
        "profile-update-interval": "12",
    })

# ===== SETTINGS =====
@app.get("/api/settings")
def get_settings(a=Depends(verify_token)):
    c = get_db(); r = c.execute("SELECT key,value FROM settings").fetchall(); c.close()
    return {x["key"]:x["value"] for x in r}

@app.put("/api/settings")
def save_settings(data: dict, a=Depends(verify_token)):
    c = get_db()
    for k,v in data.items(): c.execute("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)",(k,str(v)))
    c.commit(); c.close(); return {"ok":True}

# ===== SYSTEM STATS =====
@app.get("/api/system/stats")
def sys_stats(a=Depends(verify_token)):
    cpu = psutil.cpu_percent(interval=1)
    m = psutil.virtual_memory(); d = psutil.disk_usage('/'); n = psutil.net_io_counters()
    return {"cpu":cpu,"ram_pct":m.percent,"ram_used":round(m.used/1073741824,1),"ram_total":round(m.total/1073741824,1),
            "disk_pct":d.percent,"disk_used":round(d.used/1073741824,1),"disk_total":round(d.total/1073741824,1),
            "net_up":round(n.bytes_sent/1073741824,2),"net_down":round(n.bytes_recv/1073741824,2)}

@app.get("/api/system/connections")
def sys_conns(a=Depends(verify_token)):
    try:
        import requests as _r
        r = _r.get("http://127.0.0.1:9090/connections",headers={"Authorization":"Bearer vpnpanel2024"},timeout=3)
        conns = r.json().get("connections",[])
        return {"total":len(conns),"list":conns[:20]}
    except: return {"total":0,"list":[]}

# ===== EXTEND =====
@app.post("/api/users/{uid}/extend")
def extend_user(uid: str, data: dict, a=Depends(verify_token)):
    import time as _t
    days = int(data.get("days",30))
    c = get_db(); u = c.execute("SELECT expire_at FROM users WHERE id=?",(uid,)).fetchone()
    if not u: c.close(); raise HTTPException(404)
    now = int(_t.time())
    new_exp = max(u["expire_at"] or now, now) + days*86400
    c.execute("UPDATE users SET expire_at=?,status=\'active\' WHERE id=?",(new_exp,uid))
    c.commit(); c.close(); return {"ok":True,"expire_at":new_exp}

# ===== RESET SUB TOKEN =====
@app.post("/api/users/{uid}/reset-sub")
def reset_sub(uid: str, a=Depends(verify_token)):
    tok = _sec.token_urlsafe(24)
    c = get_db(); c.execute("UPDATE users SET sub_token=? WHERE id=?",(tok,uid)); c.commit(); c.close()
    return {"sub_token":tok}

# ===== TEST NOTIFY =====
@app.post("/api/system/notify-test")
def notify_test(a=Depends(verify_token)):
    _sys.path.insert(0,'/opt/vpn_panel/backend')
    try:
        from tg_notify import send
        send("✅ <b>Тест уведомления</b>\nПанель работает нормально!")
        return {"ok":True}
    except Exception as e: return {"ok":False,"error":str(e)}

# ===== BULK ACTIONS =====
@app.post("/api/users/bulk")
def bulk_users(data: dict, admin=Depends(verify_token)):
    action = data.get("action")
    ids = data.get("ids", [])
    conn = get_db()
    if action == "delete":
        for uid in ids:
            conn.execute("DELETE FROM users WHERE id=?", (uid,))
    elif action == "disable":
        for uid in ids:
            conn.execute("UPDATE users SET status='disabled' WHERE id=?", (uid,))
    elif action == "enable":
        for uid in ids:
            conn.execute("UPDATE users SET status='active' WHERE id=?", (uid,))
    elif action == "reset_traffic":
        for uid in ids:
            conn.execute("UPDATE users SET data_used=0 WHERE id=?", (uid,))
    conn.commit()
    conn.close()
    return {"ok": True, "affected": len(ids)}

# ===== RESET USER TRAFFIC =====
@app.post("/api/users/{uid}/reset-traffic")
def reset_traffic(uid: str, admin=Depends(verify_token)):
    conn = get_db()
    conn.execute("UPDATE users SET data_used=0 WHERE id=?", (uid,))
    conn.commit()
    conn.close()
    return {"ok": True}

# ===== TRAFFIC STATS BY PERIOD =====
@app.get("/api/traffic/period")
def traffic_period(period: str = "today", admin=Depends(verify_token)):
    import time as _t
    now = int(_t.time())
    if period == "today":
        start = now - (now % 86400)
    elif period == "week":
        start = now - 7 * 86400
    elif period == "month":
        start = now - 30 * 86400
    else:
        start = 0
    conn = get_db()
    total = conn.execute(
        "SELECT SUM(data_used) FROM users WHERE created_at>=?", (start,)
    ).fetchone()[0] or 0
    active = conn.execute(
        "SELECT COUNT(*) FROM users WHERE status='active'"
    ).fetchone()[0]
    conn.close()
    return {"period": period, "total_bytes": total, "active_users": active}

# ===== ONLINE USERS =====
@app.get("/api/users/online")
def online_users(admin=Depends(verify_token)):
    try:
        import requests as _r
        r = _r.get("http://127.0.0.1:9090/connections",
                   headers={"Authorization": "Bearer vpnpanel2024"}, timeout=3)
        conns = r.json().get("connections", [])
        online = {}
        for c in conns:
            meta = c.get("metadata", {})
            rule = c.get("rule", "")
            online[c["id"]] = {
                "upload": c.get("upload", 0),
                "download": c.get("download", 0),
                "network": meta.get("network", ""),
                "host": meta.get("host", ""),
            }
        return {"total": len(online), "connections": online}
    except:
        return {"total": 0, "connections": {}}

# ===== EXPIRING SOON =====
@app.get("/api/users/expiring")
def expiring_users(days: int = 3, admin=Depends(verify_token)):
    import time as _t
    now = int(_t.time())
    soon = now + days * 86400
    conn = get_db()
    users = conn.execute(
        "SELECT id,username,expire_at,data_used,data_limit,status FROM users WHERE expire_at>? AND expire_at<? AND status='active'",
        (now, soon)
    ).fetchall()
    conn.close()
    return [{"id":u["id"],"username":u["username"],"expire_at":u["expire_at"],
             "expires_in_hours": round((u["expire_at"]-now)/3600,1)} for u in users]

# ===== UPDATE USER NOTE =====
@app.patch("/api/users/{uid}/note")
def update_note(uid: str, data: dict, admin=Depends(verify_token)):
    conn = get_db()
    conn.execute("UPDATE users SET note=? WHERE id=?", (data.get("note",""), uid))
    conn.commit()
    conn.close()
    return {"ok": True}

# ===== USER DETAIL =====

@app.get("/api/logs/autodiag")
def get_autodiag_log(admin=Depends(verify_token)):
    try:
        with open('/opt/vpn_panel/autodiag.log', 'r') as f:
            lines = f.readlines()
        # Последние 100 строк в обратном порядке
        lines = [l.strip() for l in lines if l.strip()][-100:]
        lines.reverse()
        return {"lines": lines}
    except:
        return {"lines": []}

@app.get("/api/logs")
def get_audit(limit: int = 50, admin=Depends(verify_token)):
    conn = get_db()
    rows = conn.execute(
        "SELECT * FROM audit_log ORDER BY created_at DESC LIMIT ?", (limit,)
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]

# ===== EXPORT CSV =====
from fastapi.responses import StreamingResponse
import csv, io



# ===== INBOUNDS MANAGEMENT =====
import json as _json

def read_singbox_config():
    with open('/etc/sing-box/config.json', 'r') as f:
        return _json.load(f)

def write_singbox_config(cfg):
    with open('/etc/sing-box/config.json', 'w') as f:
        _json.dump(cfg, f, indent=2)

def restart_singbox():
    import subprocess
    subprocess.run(['systemctl', 'restart', 'sing-box'], capture_output=True)

@app.get("/api/inbounds")
def get_inbounds(admin=Depends(verify_token)):
    cfg = read_singbox_config()
    result = []
    for i in cfg.get('inbounds', []):
        result.append({
            'tag': i.get('tag'),
            'type': i.get('type'),
            'port': i.get('listen_port'),
            'listen': i.get('listen', '::'),
            'tls': 'tls' in i,
            'raw': i
        })
    return result

@app.put("/api/inbounds/{tag}")
def update_inbound(tag: str, data: dict, admin=Depends(verify_token)):
    cfg = read_singbox_config()
    for i in cfg.get('inbounds', []):
        if i.get('tag') == tag:
            if 'port' in data:
                i['listen_port'] = int(data['port'])
            if 'listen' in data:
                i['listen'] = data['listen']
            break
    write_singbox_config(cfg)
    restart_singbox()
    return {"ok": True}

@app.post("/api/inbounds/{tag}/toggle")
def toggle_inbound(tag: str, admin=Depends(verify_token)):
    cfg = read_singbox_config()
    inbounds = cfg.get('inbounds', [])
    found = None
    for i in inbounds:
        if i.get('tag') == tag:
            found = i
            break
    if not found:
        raise HTTPException(404)
    # Отключаем/включаем через disabled поле
    found['_disabled'] = not found.get('_disabled', False)
    if found['_disabled']:
        cfg['inbounds'] = [i for i in inbounds if i.get('tag') != tag]
        cfg['_disabled_inbounds'] = cfg.get('_disabled_inbounds', [])
        cfg['_disabled_inbounds'].append(found)
    else:
        cfg['_disabled_inbounds'] = [i for i in cfg.get('_disabled_inbounds',[]) if i.get('tag') != tag]
        cfg['inbounds'].append(found)
    write_singbox_config(cfg)
    restart_singbox()
    return {"ok": True, "disabled": found.get('_disabled', False)}

@app.get("/api/inbounds/{tag}/clients")
def get_inbound_clients(tag: str, admin=Depends(verify_token)):
    cfg = read_singbox_config()
    for i in cfg.get('inbounds', []):
        if i.get('tag') == tag:
            users = i.get('users', [])
            return {"tag": tag, "clients": len(users), "users": users[:10]}
    return {"tag": tag, "clients": 0, "users": []}


@app.get("/api/users/{uid}")
def get_user(uid: str, admin=Depends(verify_token)):
    conn = get_db()
    u = conn.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
    conn.close()
    if not u: raise HTTPException(404)
    return dict(u)

# ===== DAILY TRAFFIC CHART =====
@app.get("/api/traffic/daily")
def traffic_daily(days: int = 7, admin=Depends(verify_token)):
    import time as _t
    now = int(_t.time())
    conn = get_db()
    result = []
    for i in range(days-1, -1, -1):
        day_start = now - (i+1)*86400
        day_end = now - i*86400
        label = _t.strftime('%d.%m', _t.localtime(day_end))
        # Новые пользователи за день
        new_users = conn.execute(
            "SELECT COUNT(*) FROM users WHERE created_at>=? AND created_at<?",
            (day_start, day_end)
        ).fetchone()[0]
        # Активные пользователи
        active = conn.execute(
            "SELECT COUNT(*) FROM users WHERE status='active' AND created_at<=?",
            (day_end,)
        ).fetchone()[0]
        # Трафик (приблизительно - data_used накопительно)
        traffic = conn.execute(
            "SELECT COALESCE(SUM(data_used),0) FROM users"
        ).fetchone()[0]
        result.append({
            "label": label,
            "new_users": new_users,
            "active_users": active,
            "traffic_gb": round(traffic/1073741824, 2)
        })
    conn.close()
    return result

# ===== WEBHOOK =====
import threading as _threading

def send_webhook(event: str, data: dict):
    """Отправляет webhook в фоне - не блокирует основной поток"""
    def _send():
        try:
            conn = get_db()
            url = conn.execute("SELECT value FROM settings WHERE key='webhook_url'").fetchone()
            secret = conn.execute("SELECT value FROM settings WHERE key='webhook_secret'").fetchone()
            conn.close()
            if not url or not url[0]: return
            import requests as _r, json as _j, hmac as _h, hashlib as _hs
            payload = _j.dumps({"event": event, "data": data, "timestamp": int(__import__("time").time())})
            headers = {"Content-Type": "application/json"}
            if secret and secret[0]:
                sig = _h.new(secret[0].encode(), payload.encode(), _hs.sha256).hexdigest()
                headers["X-Webhook-Signature"] = sig
            _r.post(url[0], data=payload, headers=headers, timeout=5)
        except: pass
    _threading.Thread(target=_send, daemon=True).start()

@app.get("/api/webhook/settings")
def get_webhook(admin=Depends(verify_token)):
    conn = get_db()
    url = conn.execute("SELECT value FROM settings WHERE key='webhook_url'").fetchone()
    secret = conn.execute("SELECT value FROM settings WHERE key='webhook_secret'").fetchone()
    events = conn.execute("SELECT value FROM settings WHERE key='webhook_events'").fetchone()
    conn.close()
    return {
        "url": url[0] if url else "",
        "secret": secret[0] if secret else "",
        "events": (events[0] if events else "user_expired,node_down,overlimit").split(",")
    }

@app.put("/api/webhook/settings")
def save_webhook(data: dict, admin=Depends(verify_token)):
    conn = get_db()
    conn.execute("INSERT OR REPLACE INTO settings (key,value) VALUES ('webhook_url',?)", (data.get("url",""),))
    conn.execute("INSERT OR REPLACE INTO settings (key,value) VALUES ('webhook_secret',?)", (data.get("secret",""),))
    events = ",".join(data.get("events", []))
    conn.execute("INSERT OR REPLACE INTO settings (key,value) VALUES ('webhook_events',?)", (events,))
    conn.commit()
    conn.close()
    return {"ok": True}

@app.post("/api/webhook/test")
def test_webhook(admin=Depends(verify_token)):
    send_webhook("test", {"message": "Test webhook from VPN Panel"})
    return {"ok": True, "message": "Webhook отправлен в фоне"}

# ===== FULL INBOUND EDIT =====
@app.put("/api/inbounds/{tag}/full")
def update_inbound_full(tag: str, data: dict, admin=Depends(verify_token)):
    cfg = read_singbox_config()
    for ib in cfg.get('inbounds', []):
        if ib.get('tag') == tag:
            if 'port' in data: ib['listen_port'] = int(data['port'])
            if 'listen' in data: ib['listen'] = data['listen']
            if 'sni' in data and 'tls' in ib:
                ib['tls']['server_name'] = data['sni']
                if 'reality' in ib['tls']:
                    ib['tls']['reality']['handshake']['server'] = data['sni']
            if 'hs_server' in data and 'tls' in ib and 'reality' in ib['tls']:
                ib['tls']['reality']['handshake']['server'] = data['hs_server']
            if 'hs_port' in data and 'tls' in ib and 'reality' in ib['tls']:
                ib['tls']['reality']['handshake']['server_port'] = int(data['hs_port'])
            if 'short_id' in data and 'tls' in ib and 'reality' in ib['tls']:
                ib['tls']['reality']['short_id'] = [data['short_id']]
            break
    write_singbox_config(cfg)
    restart_singbox()
    return {"ok": True}

@app.post("/api/inbounds/add")
def add_inbound(data: dict, admin=Depends(verify_token)):
    cfg = read_singbox_config()
    import uuid as _uuid
    new_ib = {
        "type": data.get("type", "vless"),
        "tag": data.get("tag", "vless-new"),
        "listen": "::",
        "listen_port": int(data.get("port", 443)),
    }
    if data["type"] == "vless":
        new_ib["users"] = [u for ib in cfg.get("inbounds",[]) if ib.get("type")=="vless" for u in ib.get("users",[])]
        new_ib["tls"] = {
            "enabled": True,
            "server_name": data.get("sni","www.microsoft.com"),
            "reality": {
                "enabled": True,
                "handshake": {"server": data.get("sni","www.microsoft.com"), "server_port": 443},
                "private_key": cfg["inbounds"][0]["tls"]["reality"]["private_key"] if cfg.get("inbounds") else "",
                "short_id": [_uuid.uuid4().hex[:16]]
            }
        }
    elif data["type"] == "hysteria2":
        new_ib["users"] = [u for ib in cfg.get("inbounds",[]) if ib.get("type")=="hysteria2" for u in ib.get("users",[])]
        new_ib["tls"] = {"enabled": True, "certificate_path": "/etc/sing-box/cert.pem", "key_path": "/etc/sing-box/key.pem"}
    cfg["inbounds"].append(new_ib)
    write_singbox_config(cfg)
    restart_singbox()
    return {"ok": True}

@app.delete("/api/inbounds/{tag}")
def delete_inbound(tag: str, admin=Depends(verify_token)):
    cfg = read_singbox_config()
    cfg["inbounds"] = [ib for ib in cfg.get("inbounds",[]) if ib.get("tag") != tag]
    write_singbox_config(cfg)
    restart_singbox()
    return {"ok": True}

@app.post("/api/subadmins/{admin_id}/change-password")
def change_admin_password(admin_id: int, data: dict, admin=Depends(verify_token)):
    import hashlib
    conn = get_db()
    new_hash = hashlib.sha256(data.get("password","").encode()).hexdigest()
    conn.execute("UPDATE admins SET password=? WHERE id=?", (new_hash, admin_id))
    conn.commit()
    conn.close()
    return {"ok": True}

# ===== TRAFFIC ANALYTICS =====
@app.get("/api/traffic/hourly")
def traffic_hourly(hours: int = 24, admin=Depends(verify_token)):
    conn = get_db()
    now = int(time.time())
    since = now - hours * 3600
    since_hour = since - (since % 3600)
    
    rows = conn.execute(
        "SELECT hour, protocol, node_id, bytes_up, bytes_down FROM traffic_hourly WHERE hour >= ? ORDER BY hour",
        (since_hour,)
    ).fetchall()
    conn.close()
    
    result = {}
    for r in rows:
        h = r[0]
        label = __import__('datetime').datetime.fromtimestamp(h).strftime('%H:%M')
        key = f"{h}"
        if key not in result:
            result[key] = {"label": label, "hour": h, "vless_up": 0, "vless_down": 0, "hy2_up": 0, "hy2_down": 0, "main_up": 0, "main_down": 0, "ru75_up": 0, "ru75_down": 0}
        proto = r[1]
        node = r[2]
        if proto == 'vless':
            result[key]["vless_up"] += r[3]
            result[key]["vless_down"] += r[4]
        elif proto == 'hysteria2':
            result[key]["hy2_up"] += r[3]
            result[key]["hy2_down"] += r[4]
        if node == 'main':
            result[key]["main_up"] += r[3]
            result[key]["main_down"] += r[4]
        elif node == 'ru75':
            result[key]["ru75_up"] += r[3]
            result[key]["ru75_down"] += r[4]
    
    # Конвертируем в MB
    data = sorted(result.values(), key=lambda x: x["hour"])
    for d in data:
        for k in ["vless_up","vless_down","hy2_up","hy2_down","main_up","main_down","ru75_up","ru75_down"]:
            d[k] = round(d[k] / 1024**2, 2)
    return data

@app.get("/api/traffic/by-protocol")
def traffic_by_protocol(days: int = 7, admin=Depends(verify_token)):
    conn = get_db()
    now = int(time.time())
    since = now - days * 86400
    rows = conn.execute(
        "SELECT protocol, SUM(bytes_up), SUM(bytes_down) FROM traffic_hourly WHERE hour >= ? GROUP BY protocol",
        (since,)
    ).fetchall()
    conn.close()
    return [{"protocol": r[0], "upload_gb": round(r[1]/1024**3,2), "download_gb": round(r[2]/1024**3,2)} for r in rows]

@app.get("/api/traffic/by-node")
def traffic_by_node(days: int = 7, admin=Depends(verify_token)):
    conn = get_db()
    now = int(time.time())
    since = now - days * 86400
    rows = conn.execute(
        "SELECT node_id, SUM(bytes_up), SUM(bytes_down) FROM traffic_hourly WHERE hour >= ? GROUP BY node_id",
        (since,)
    ).fetchall()
    conn.close()
    return [{"node": r[0], "upload_gb": round(r[1]/1024**3,2), "download_gb": round(r[2]/1024**3,2)} for r in rows]

@app.get("/api/bandwidth")
def get_bandwidth(admin=Depends(verify_token)):
    conn = get_db()
    now = int(time.time())
    
    def get_traffic(since):
        # Из traffic_hourly если есть данные
        r2 = conn.execute(
            "SELECT SUM(bytes_up+bytes_down) FROM traffic_hourly WHERE hour >= ?",
            (since,)
        ).fetchone()
        val = r2[0] if r2 and r2[0] else 0
        if val > 0: return val
        # Fallback - общий трафик из users
        r = conn.execute("SELECT SUM(data_used) FROM users").fetchone()
        return r[0] if r and r[0] else 0
    
    def fmt(b):
        if b >= 1024**3: return f"{round(b/1024**3,2)} GB"
        if b >= 1024**2: return f"{round(b/1024**2,1)} MB"
        return f"{round(b/1024,1)} KB"
    
    today_start = now - (now % 86400)
    week_start = now - 7*86400
    month_start = now - 30*86400
    prev_week_start = now - 14*86400
    prev_month_start = now - 60*86400
    
    # Получаем общий трафик из users
    total = conn.execute("SELECT SUM(data_used) FROM users").fetchone()[0] or 0
    
    t_today = get_traffic(today_start)
    t_7d = get_traffic(week_start)
    t_30d = get_traffic(month_start)
    t_prev_week = get_traffic(prev_week_start) - t_7d
    t_prev_month = get_traffic(prev_month_start) - t_30d
    
    # Calendar month
    import datetime as _dt
    now_dt = _dt.datetime.now()
    month_begin = int(_dt.datetime(now_dt.year, now_dt.month, 1).timestamp())
    t_cal_month = get_traffic(month_begin)
    
    # Year
    year_begin = int(_dt.datetime(now_dt.year, 1, 1).timestamp())
    t_year = get_traffic(year_begin)
    
    conn.close()
    
    def diff(cur, prev):
        if prev == 0: return ""
        d = cur - prev
        sign = "↑" if d >= 0 else "↓"
        color = "var(--green)" if d >= 0 else "var(--red)"
        return {"text": sign+" "+fmt(abs(d)), "color": color}
    
    return {
        "today": fmt(t_today),
        "today_vs": diff(t_today, t_today),
        "last_7d": fmt(t_7d),
        "last_7d_vs": diff(t_7d, t_prev_week),
        "last_30d": fmt(t_30d),
        "last_30d_vs": diff(t_30d, t_prev_month),
        "cal_month": fmt(t_cal_month),
        "year": fmt(t_year),
        "total": fmt(total)
    }

@app.get("/api/users/{user_id}/stats")
def user_stats(user_id: str, admin=Depends(verify_token)):
    conn = get_db()
    # Берём данные из traffic_hourly (реальный трафик по протоколам/нодам)
    rows = conn.execute(
        "SELECT protocol, node_id, SUM(bytes_up+bytes_down) as total FROM traffic_hourly GROUP BY protocol, node_id"
    ).fetchall()
    # Берём data_used пользователя
    user = conn.execute("SELECT data_used, data_limit FROM users WHERE id=?", (user_id,)).fetchone()
    result = {"vless": 0, "hysteria2": 0, "nodes": {}}
    # Считаем пропорцию трафика пользователя
    total_all = sum(r[2] or 0 for r in rows)
    user_used = user["data_used"] if user else 0
    ratio = (user_used / total_all) if total_all > 0 else 1.0
    for r in rows:
        proto = r[0]; node = r[1]; total = int((r[2] or 0) * ratio)
        if proto == "vless": result["vless"] += total
        elif proto == "hysteria2": result["hysteria2"] += total
        if node not in result["nodes"]: result["nodes"][node] = 0
        result["nodes"][node] += total
    conn.close()
    return result


@app.get("/api/users/{user_id}/keys")
def get_user_keys(user_id: str, admin=Depends(verify_token)):
    conn = get_db()
    user = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
    conn.close()
    if not user:
        raise HTTPException(status_code=404)
    # Получаем UUID из subscription_url
    import re as _re
    user_uuid = user["id"]
    if user["subscription_url"] and "vless://" in user["subscription_url"]:
        m = _re.search(r"vless://([^@]+)@", user["subscription_url"])
        if m: user_uuid = m.group(1)
    keys = keygen.generate_keys(user_uuid)
    result = []
    for k, v in keys.items():
        if k in ("vless_main", "vless"): continue
        if "vless" in k.lower():
            result.append({"label": k.replace("vless_","").replace("_"," ").title(), "type": "vless", "key": v})
        elif "hy2" in k.lower():
            result.append({"label": k.replace("hy2_","").replace("_"," ").title(), "type": "hysteria2", "key": v})
    conn2 = get_db()
    sub_tok = conn2.execute("SELECT sub_token FROM users WHERE id=?", (user_id,)).fetchone()
    conn2.close()
    settings = {}
    try:
        c = get_db()
        rows = c.execute("SELECT key,value FROM settings").fetchall()
        c.close()
        settings = {r["key"]:r["value"] for r in rows}
    except: pass
    domain = settings.get("panel_domain","").rstrip("/") or ""
    sub_url = f"{domain}/sub/{sub_tok['sub_token']}" if sub_tok and sub_tok['sub_token'] else ""
    return {"keys": result, "sub_url": sub_url, "username": user["username"]}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PANEL_PORT", "8080")))




@app.get("/api/users/export")
def export_users(admin=Depends(verify_token)):
    conn = get_db()
    users = conn.execute("SELECT * FROM users").fetchall()
    conn.close()
    output = io.StringIO()
    w = csv.writer(output)
    w.writerow(['username','status','data_used_gb','data_limit_gb','expire_at','note','created_at'])
    for u in users:
        w.writerow([
            u['username'], u['status'],
            round((u['data_used'] or 0)/1073741824, 3),
            round((u['data_limit'] or 0)/1073741824, 3),
            u['expire_at'], u['note'] or '', u['created_at']
        ])
    output.seek(0)
    return StreamingResponse(
        iter([output.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=users.csv"}
    )

# ===== IMPORT CSV =====
from fastapi import UploadFile, File
import secrets as _secrets

@app.post("/api/users/import")
async def import_users(file: UploadFile = File(...), admin=Depends(verify_token)):
    content = await file.read()
    reader = csv.DictReader(io.StringIO(content.decode()))
    conn = get_db()
    added = 0
    for row in reader:
        try:
            uid = __import__('uuid').uuid4().hex[:12]
            expire_days = 30
            data_limit = int(float(row.get('data_limit_gb','0') or 0) * 1073741824)
            now = int(__import__('time').time())
            expire_at = now + expire_days * 86400
            sub_token = _secrets.token_urlsafe(24)
            conn.execute(
                "INSERT OR IGNORE INTO users (id,username,status,data_used,data_limit,expire_at,note,sub_token,created_at) VALUES (?,?,?,0,?,?,?,?,?)",
                (uid, row['username'], 'active', data_limit, expire_at, row.get('note',''), sub_token, now)
            )
            added += 1
        except: pass
    conn.commit()
    conn.close()
    return {"ok": True, "added": added}

# ===== USER TEMPLATES =====
@app.get("/api/templates")
def get_templates(admin=Depends(verify_token)):
    conn = get_db()
    try:
        rows = conn.execute("SELECT * FROM user_templates ORDER BY id").fetchall()
        conn.close()
        return [dict(r) for r in rows]
    except:
        conn.close()
        return []

@app.post("/api/templates")
def create_template(data: dict, admin=Depends(verify_token)):
    conn = get_db()
    conn.execute(
        "INSERT INTO user_templates (name, expire_days, data_limit_gb, note) VALUES (?,?,?,?)",
        (data['name'], data.get('expire_days',30), data.get('data_limit_gb',0), data.get('note',''))
    )
    conn.commit()
    conn.close()
    return {"ok": True}

@app.delete("/api/templates/{tid}")
def delete_template(tid: int, admin=Depends(verify_token)):
    conn = get_db()
    conn.execute("DELETE FROM user_templates WHERE id=?", (tid,))
    conn.commit()
    conn.close()
    return {"ok": True}

# ===== BACKUP =====
import shutil, os

@app.get("/api/backup")
def backup_db(admin=Depends(verify_token)):
    src = "/opt/vpn_panel/backend/vpn_panel.db"
    ts = __import__('time').strftime('%Y%m%d_%H%M%S')
    dst = f"/opt/vpn_panel/backend/backup_{ts}.db"
    shutil.copy2(src, dst)
    return StreamingResponse(
        open(dst, 'rb'),
        media_type="application/octet-stream",
        headers={"Content-Disposition": f"attachment; filename=vpn_panel_{ts}.db"}
    )

# ===== TRAFFIC CHART DATA =====
@app.get("/api/traffic/chart")
def traffic_chart(days: int = 7, admin=Depends(verify_token)):
    import time as _t
    now = int(_t.time())
    conn = get_db()
    result = []
    for i in range(days-1, -1, -1):
        day_start = now - (i+1)*86400
        day_end = now - i*86400
        total = conn.execute(
            "SELECT COUNT(*) FROM users WHERE created_at>=? AND created_at<?",
            (day_start, day_end)
        ).fetchone()[0]
        label = _t.strftime('%d.%m', _t.localtime(day_end))
        result.append({"label": label, "new_users": total})
    conn.close()
    return result


FILEEOF
echo '📄 Распаковка /opt/vpn_panel/backend/keygen.py...'
cat <<'FILEEOF' > /opt/vpn_panel/backend/keygen.py
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
                                    pbk = _r.get("public_key", "")
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

        elif tag == "hysteria2-in":
            key = f"hysteria2://{uuid}@{address}:{port}?insecure=1&sni={sni}#{remark}"
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

FILEEOF
echo '📄 Распаковка /opt/vpn_panel/backend/traffic_monitor.py...'
cat <<'FILEEOF' > /opt/vpn_panel/backend/traffic_monitor.py
import sqlite3, time, requests, sys, json
sys.path.insert(0, '/opt/vpn_panel/backend')
DB_PATH = '/opt/vpn_panel/backend/vpn_panel.db'
_prev = {}

_logged_ips = {}  # ip -> timestamp последнего логирования

def log_connection(source_ip, protocol, node_id):
    """Записывает новое соединение в connection_logs"""
    if not source_ip: return
    key = (source_ip, protocol, node_id)
    now = int(time.time())
    # Логируем одно соединение раз в 5 минут
    if key in _logged_ips and now - _logged_ips[key] < 300:
        return
    _logged_ips[key] = now
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    # Находим пользователя - берём первого активного (потом можно улучшить)
    user = conn.execute("SELECT id, username FROM users WHERE status='active' LIMIT 1").fetchone()
    if user:
        conn.execute("""INSERT INTO connection_logs 
            (user_id, username, protocol, node_id, ip, timestamp)
            VALUES (?,?,?,?,?,?)""",
            (user['id'], user['username'], protocol, node_id, source_ip, now))
        conn.commit()
    conn.close()


def get_db():
    conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row; return conn
def get_nodes():
    conn = get_db()
    rows = conn.execute("SELECT id, host FROM nodes WHERE status='online'").fetchall()
    conn.close()
    result = {}
    for r in rows:
        host = '127.0.0.1' if r['host'] in ('185.40.4.169','ru75.alexanderoff.store') else r['host']
        result[r['id']] = {'host': host, 'port': 9090, 'secret': ''}
    return result
def get_settings():
    conn = get_db()
    rows = conn.execute("SELECT key,value FROM settings").fetchall()
    conn.close()
    return {r['key']: r['value'] for r in rows}
def get_all_active_users():
    conn = get_db()
    rows = conn.execute("SELECT id FROM users WHERE status='active'").fetchall()
    conn.close()
    return [r['id'] for r in rows]
def collect_node(node_id, node):
    try:
        r = requests.get(f'http://{node["host"]}:{node["port"]}/connections',
            headers={'Authorization': f'Bearer {node["secret"]}'}, timeout=5)
        if r.status_code != 200: return {}
        conns = r.json().get('connections', [])
        result = {}
        for c in conns:
            cid = c['id']
            upload = c.get('upload', 0); download = c.get('download', 0)
            conn_type = c.get('metadata', {}).get('type', '')
            if 'hysteria2' in conn_type: protocol = 'hysteria2'
            elif 'vless' in conn_type: protocol = 'vless'
            else: protocol = 'unknown'
            source_ip = c.get('metadata', {}).get('sourceIP', '')
            if cid in _prev:
                prev = _prev[cid]
                up_d = max(0, upload - prev['upload'])
                dn_d = max(0, download - prev['download'])
            else:
                up_d = dn_d = 0
            _prev[cid] = {'upload': upload, 'download': download}
            log_connection(source_ip, protocol, node_id)
            if up_d > 0 or dn_d > 0:
                result[cid] = {'upload_delta': up_d, 'download_delta': dn_d,
                               'protocol': protocol, 'source_ip': source_ip, 'node_id': node_id}
        active_ids = {c['id'] for c in conns}
        for k in list(_prev.keys()):
            if k not in active_ids: del _prev[k]
        return result
    except Exception as e:
        print(f"collect_node error [{node_id}]: {e}"); return {}
def update_db(node_id, connections_data):
    if not connections_data: return
    conn = get_db(); now = int(time.time())
    hour = int(now // 3600) * 3600
    proto_stats = {}; total_up = 0; total_down = 0
    for cid, data in connections_data.items():
        proto = data['protocol']
        if proto not in proto_stats: proto_stats[proto] = {'up': 0, 'down': 0}
        proto_stats[proto]['up'] += data['upload_delta']
        proto_stats[proto]['down'] += data['download_delta']
        total_up += data['upload_delta']; total_down += data['download_delta']
    exists = conn.execute("SELECT id FROM node_traffic WHERE node_id=?", (node_id,)).fetchone()
    if exists:
        conn.execute("UPDATE node_traffic SET bytes_up=bytes_up+?,bytes_down=bytes_down+?,updated_at=? WHERE node_id=?",
            (total_up, total_down, now, node_id))
    else:
        conn.execute("INSERT INTO node_traffic (node_id,bytes_up,bytes_down,updated_at) VALUES (?,?,?,?)",
            (node_id, total_up, total_down, now))
    for proto, stats in proto_stats.items():
        ex = conn.execute("SELECT id FROM traffic_hourly WHERE hour=? AND protocol=? AND node_id=?",
            (hour, proto, node_id)).fetchone()
        if ex:
            conn.execute("UPDATE traffic_hourly SET bytes_up=bytes_up+?,bytes_down=bytes_down+? WHERE hour=? AND protocol=? AND node_id=?",
                (stats['up'], stats['down'], hour, proto, node_id))
        else:
            conn.execute("INSERT INTO traffic_hourly (hour,protocol,node_id,bytes_up,bytes_down) VALUES (?,?,?,?,?)",
                (hour, proto, node_id, stats['up'], stats['down']))
    total_delta = total_up + total_down
    if total_delta > 0:
        active_users = get_all_active_users()
        if active_users:
            per_user = total_delta // len(active_users)
            if per_user > 0:
                for uid in active_users:
                    conn.execute("UPDATE users SET data_used=data_used+? WHERE id=?", (per_user, uid))
    conn.commit(); conn.close()
    for proto, stats in proto_stats.items():
        total = stats['up'] + stats['down']
        if total > 0:
            print(f"📊 [{node_id}] {proto}: ↑{round(stats['up']/1024,1)}KB ↓{round(stats['down']/1024,1)}KB")
def check_limits():
    try:
        from tg_notify import user_expired, user_overlimit; tg_ok = True
    except: tg_ok = False
    s = get_settings(); notify_users = s.get('tg_notify_user','1') == '1'
    conn = get_db(); now = int(time.time())
    expired = conn.execute("SELECT id,username FROM users WHERE expire_at>0 AND expire_at<? AND status='active'", (now,)).fetchall()
    for u in expired:
        conn.execute("UPDATE users SET status='expired' WHERE id=?", (u['id'],))
        print(f"⏰ {u['username']} истёк")
        if tg_ok and notify_users:
            try: user_expired(u['username'])
            except: pass
    overlimit = conn.execute("SELECT id,username FROM users WHERE data_limit>0 AND data_used>=data_limit AND status='active'").fetchall()
    for u in overlimit:
        conn.execute("UPDATE users SET status='overlimit' WHERE id=?", (u['id'],))
        print(f"🚫 {u['username']} превысил лимит")
        if tg_ok and notify_users:
            try: user_overlimit(u['username'])
            except: pass
    if expired or overlimit:
        conn.commit()
        import subprocess; subprocess.Popen(["python3", "/opt/vpn_panel/backend/sync_users.py"])
    conn.close()
def monitor_loop():
    print("🔍 Мониторинг трафика v2 запущен (по протоколам)")
    nodes = get_nodes()
    for node_id, node in nodes.items():
        collect_node(node_id, node); print(f"✅ Нода {node_id} инициализирована")
    while True:
        try:
            nodes = get_nodes()
            for node_id, node in nodes.items():
                data = collect_node(node_id, node)
                if data: update_db(node_id, data)
            check_limits()
        except Exception as e: print(f"Monitor error: {e}")
        time.sleep(10)
if __name__ == '__main__':
    monitor_loop()

FILEEOF
echo '📄 Распаковка /opt/vpn_panel/backend/sync_users.py...'
cat <<'FILEEOF' > /opt/vpn_panel/backend/sync_users.py
import json, sqlite3, os, sys
sys.path.insert(0, '/opt/vpn_panel/venv/lib/python3.12/site-packages')
import paramiko

DB_PATH = '/opt/vpn_panel/backend/vpn_panel.db'

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def sync_main_node(uuids):
    try:
        with open('/etc/sing-box/config.json') as f:
            config = json.load(f)
        for inbound in config['inbounds']:
            if inbound.get('type') == 'vless':
                inbound['users'] = [{"uuid": u, "flow": "xtls-rprx-vision"} for u in uuids]
            elif inbound.get('type') == 'hysteria2':
                inbound['users'] = [{"password": u} for u in uuids]
        with open('/etc/sing-box/config.json', 'w') as f:
            json.dump(config, f, indent=2)
        os.system('systemctl restart sing-box')
        print(f'✅ Main: {len(uuids)} пользователей')
    except Exception as e:
        print(f'❌ Main ошибка: {e}')

def sync_remote_node(node):
    host     = node['host']
    ssh_port = node['port'] or 22
    ssh_user = node['ssh_user'] or 'root'
    ssh_pass = node['ssh_password'] or ''
    name     = node['name']
    if not ssh_pass:
        print(f'⚠️ {name}: нет SSH пароля, пропускаем')
        return
    try:
        conn = get_db()
        uuids = [u['id'] for u in conn.execute("SELECT id FROM users WHERE status='active'").fetchall()]
        conn.close()
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        ssh.connect(host, port=ssh_port, username=ssh_user, password=ssh_pass, timeout=15)
        stdin, stdout, stderr = ssh.exec_command('cat /etc/sing-box/config.json')
        cfg = json.loads(stdout.read())
        for inb in cfg.get('inbounds', []):
            if inb.get('type') == 'vless':
                inb['users'] = [{"uuid": u, "flow": "xtls-rprx-vision"} for u in uuids]
            elif inb.get('type') == 'hysteria2':
                inb['users'] = [{"password": u} for u in uuids]
        sftp = ssh.open_sftp()
        with sftp.open('/etc/sing-box/config.json', 'w') as f:
            f.write(json.dumps(cfg, indent=2))
        sftp.close()
        ssh.exec_command('systemctl restart sing-box')
        ssh.close()
        print(f'✅ {name}: {len(uuids)} пользователей')
    except Exception as e:
        print(f'❌ {name} ошибка: {e}')

def sync():
    conn = get_db()
    uuids = [u['id'] for u in conn.execute("SELECT id FROM users WHERE status='active'").fetchall()]
    nodes = [dict(n) for n in conn.execute("SELECT * FROM nodes WHERE id != 'main'").fetchall()]
    conn.close()
    print(f'Синхронизация {len(uuids)} пользователей на {len(nodes)+1} нод...')
    sync_main_node(uuids)
    for node in nodes:
        sync_remote_node(node)
    print(f'✅ Готово!')

if __name__ == '__main__':
    sync()

FILEEOF
echo '📄 Распаковка /opt/vpn_panel/frontend/index.html...'
cat <<'FILEEOF' > /opt/vpn_panel/frontend/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VPN Panel</title>
<meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
<meta http-equiv="Pragma" content="no-cache">
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;700&family=Syne:wght@400;600;700;800&display=swap" rel="stylesheet">
<style>
:root {
  --bg: #090c10;
  --bg2: #0d1117;
  --bg3: #161b22;
  --bg4: #1c2333;
  --border: #21262d;
  --border2: #30363d;
  --text: #e6edf3;
  --muted: #7d8590;
  --accent: #2f81f7;
  --accent2: #3fb950;
  --accent3: #f78166;
  --accent4: #d2a8ff;
  --yellow: #e3b341;
  --cyan: #39d0d8;
  --red: #f85149;
  --green: #3fb950;
  --glow: rgba(47,129,247,0.15);
}
*{margin:0;padding:0;box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:'Syne',sans-serif;min-height:100vh;overflow-x:hidden}
body::before{content:'';position:fixed;top:0;left:0;right:0;height:1px;background:linear-gradient(90deg,transparent,var(--accent),transparent);z-index:100}

/* LAYOUT */
.app{display:flex;height:100vh;overflow:hidden}
.sidebar{width:220px;min-width:220px;background:var(--bg2);border-right:1px solid var(--border);display:flex;flex-direction:column;overflow-y:auto}
.main{flex:1;overflow-y:auto;background:var(--bg)}

/* SIDEBAR */
.logo{padding:20px 16px 16px;border-bottom:1px solid var(--border)}
.logo-text{font-size:20px;font-weight:800;letter-spacing:-0.5px}
.logo-text span{color:var(--accent)}
.logo-sub{font-size:10px;color:var(--muted);font-family:'JetBrains Mono',monospace;margin-top:2px}
.nav{padding:12px 8px;flex:1}
.nav-section{font-size:10px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:1px;padding:8px 8px 4px}
.ni{display:flex;align-items:center;gap:10px;padding:8px 10px;border-radius:8px;cursor:pointer;color:var(--muted);font-size:13px;font-weight:600;transition:all .15s;margin-bottom:2px;position:relative}
.ni:hover{background:var(--bg3);color:var(--text)}
.ni.active{background:rgba(47,129,247,0.12);color:var(--accent);border:1px solid rgba(47,129,247,0.2)}
.ni.active::before{content:'';position:absolute;left:0;top:50%;transform:translateY(-50%);width:3px;height:60%;background:var(--accent);border-radius:0 2px 2px 0}
.ni .ico{width:18px;text-align:center;font-size:14px}
.sidebar-bottom{padding:12px 8px;border-top:1px solid var(--border)}
.user-badge{display:flex;align-items:center;gap:10px;padding:8px 10px;background:var(--bg3);border-radius:8px;margin-bottom:8px}
.user-avatar{width:28px;height:28px;background:linear-gradient(135deg,var(--accent),var(--accent4));border-radius:6px;display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:700}
.user-info{flex:1;min-width:0}
.user-name{font-size:12px;font-weight:700;color:var(--text)}
.user-role{font-size:10px;color:var(--muted)}

/* PAGES */
.page{display:none;padding:24px;animation:fadeIn .2s ease}
.page.active{display:block}
@keyframes fadeIn{from{opacity:0;transform:translateY(4px)}to{opacity:1;transform:translateY(0)}}

/* PAGE HEADER */
.ph{margin-bottom:24px}
.ph-top{display:flex;align-items:center;justify-content:space-between;margin-bottom:6px}
.pt{font-size:22px;font-weight:800;letter-spacing:-0.5px}
.ps{font-size:13px;color:var(--muted)}
.ph-actions{display:flex;gap:8px}

/* BUTTONS */
.btn{display:inline-flex;align-items:center;gap:6px;padding:8px 14px;border-radius:8px;font-size:13px;font-weight:600;cursor:pointer;border:1px solid transparent;transition:all .15s;font-family:'Syne',sans-serif}
.btn-primary{background:var(--accent);color:#fff;border-color:var(--accent)}
.btn-primary:hover{background:#388bfd;box-shadow:0 0 12px rgba(47,129,247,0.4)}
.btn-secondary{background:var(--bg3);color:var(--text);border-color:var(--border2)}
.btn-secondary:hover{background:var(--bg4);border-color:var(--muted)}
.btn-danger{background:rgba(248,81,73,0.1);color:var(--red);border-color:rgba(248,81,73,0.3)}
.btn-danger:hover{background:rgba(248,81,73,0.2)}
.btn-success{background:rgba(63,185,80,0.1);color:var(--green);border-color:rgba(63,185,80,0.3)}
.btn-sm{padding:5px 10px;font-size:12px}
.btn-icon{padding:6px 8px;font-size:13px}

/* STAT CARDS */
.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin-bottom:24px}
.stat-card{background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px;position:relative;overflow:hidden;transition:border-color .2s}
.stat-card:hover{border-color:var(--border2)}
.stat-card::after{content:'';position:absolute;top:0;right:0;width:60px;height:60px;border-radius:0 12px 0 60px;opacity:0.06}
.stat-card.blue::after{background:var(--accent)}
.stat-card.green::after{background:var(--green)}
.stat-card.red::after{background:var(--red)}
.stat-card.yellow::after{background:var(--yellow)}
.stat-card.purple::after{background:var(--accent4)}
.stat-card.cyan::after{background:var(--cyan)}
.stat-label{font-size:11px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:0.5px;margin-bottom:8px}
.stat-value{font-size:26px;font-weight:800;font-family:'JetBrains Mono',monospace;letter-spacing:-1px}
.stat-card.blue .stat-value{color:var(--accent)}
.stat-card.green .stat-value{color:var(--green)}
.stat-card.red .stat-value{color:var(--red)}
.stat-card.yellow .stat-value{color:var(--yellow)}
.stat-card.purple .stat-value{color:var(--accent4)}
.stat-card.cyan .stat-value{color:var(--cyan)}
.stat-sub{font-size:11px;color:var(--muted);margin-top:4px}

/* TABLE */
.table-card{background:var(--bg2);border:1px solid var(--border);border-radius:12px;overflow:hidden;margin-bottom:20px}
.table-header{display:flex;align-items:center;justify-content:space-between;padding:14px 16px;border-bottom:1px solid var(--border)}
.table-title{font-size:14px;font-weight:700}
.table-actions{display:flex;gap:8px;align-items:center}
table{width:100%;border-collapse:collapse}
th{padding:10px 16px;text-align:left;font-size:11px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:0.5px;border-bottom:1px solid var(--border);background:rgba(0,0,0,0.2)}
td{padding:12px 16px;font-size:13px;border-bottom:1px solid rgba(33,38,45,0.5);vertical-align:middle}
tr:last-child td{border-bottom:none}
tr:hover td{background:rgba(255,255,255,0.02)}
.mono{font-family:'JetBrains Mono',monospace;font-size:12px}

/* BADGES */
.badge{display:inline-flex;align-items:center;gap:4px;padding:3px 8px;border-radius:20px;font-size:11px;font-weight:700}
.badge::before{content:'';width:5px;height:5px;border-radius:50%;background:currentColor}
.badge-green{background:rgba(63,185,80,0.12);color:var(--green);border:1px solid rgba(63,185,80,0.2)}
.badge-red{background:rgba(248,81,73,0.12);color:var(--red);border:1px solid rgba(248,81,73,0.2)}
.badge-yellow{background:rgba(227,179,65,0.12);color:var(--yellow);border:1px solid rgba(227,179,65,0.2)}
.badge-blue{background:rgba(47,129,247,0.12);color:var(--accent);border:1px solid rgba(47,129,247,0.2)}
.badge-purple{background:rgba(210,168,255,0.12);color:var(--accent4);border:1px solid rgba(210,168,255,0.2)}

/* PROGRESS */
.progress{height:4px;background:var(--bg4);border-radius:2px;overflow:hidden;margin-top:4px}
.progress-bar{height:100%;border-radius:2px;transition:width .5s ease}
.progress-bar.green{background:var(--green)}
.progress-bar.yellow{background:var(--yellow)}
.progress-bar.red{background:var(--red)}

/* NODE CARD */
.nodes-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:12px;margin-bottom:20px}
.node-card{background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px;transition:border-color .2s}
.node-card:hover{border-color:var(--border2)}
.node-card-header{display:flex;align-items:center;justify-content:space-between;margin-bottom:12px}
.node-name{font-weight:700;font-size:14px}
.node-info{display:grid;grid-template-columns:1fr 1fr;gap:8px;font-size:12px}
.node-info-item{background:var(--bg3);border-radius:6px;padding:8px}
.node-info-label{color:var(--muted);font-size:10px;text-transform:uppercase;font-weight:700;margin-bottom:2px}
.node-info-val{font-family:'JetBrains Mono',monospace;font-size:12px;color:var(--text)}

/* MODAL */
.modal-overlay{position:fixed;inset:0;background:rgba(0,0,0,0.7);backdrop-filter:blur(4px);z-index:1000;display:none;align-items:center;justify-content:center;padding:20px}
.modal-overlay.open{display:flex}
.modal{background:var(--bg2);border:1px solid var(--border2);border-radius:16px;width:100%;max-width:480px;max-height:90vh;overflow-y:auto;animation:modalIn .2s ease}
.modal.wide{max-width:640px}
@keyframes modalIn{from{opacity:0;transform:scale(0.96)}to{opacity:1;transform:scale(1)}}
.modal-header{padding:20px 20px 0;display:flex;align-items:center;justify-content:space-between}
.modal-title{font-size:16px;font-weight:800}
.modal-close{width:28px;height:28px;border-radius:6px;background:var(--bg3);border:1px solid var(--border);color:var(--muted);cursor:pointer;display:flex;align-items:center;justify-content:center;font-size:16px;transition:all .15s}
.modal-close:hover{background:var(--bg4);color:var(--text)}
.modal-body{padding:20px}
.modal-footer{padding:0 20px 20px;display:flex;gap:8px;justify-content:flex-end}

/* FORM */
.form-group{margin-bottom:14px}
.form-label{font-size:12px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:0.5px;margin-bottom:6px;display:block}
.form-input{width:100%;background:var(--bg3);border:1px solid var(--border2);border-radius:8px;padding:10px 12px;color:var(--text);font-size:13px;font-family:'Syne',sans-serif;outline:none;transition:border-color .15s}
.form-input:focus{border-color:var(--accent)}
.form-input::placeholder{color:var(--muted)}
.form-row{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.form-select{width:100%;background:var(--bg3);border:1px solid var(--border2);border-radius:8px;padding:10px 12px;color:var(--text);font-size:13px;font-family:'Syne',sans-serif;outline:none}
.checkbox-group{display:flex;flex-wrap:wrap;gap:8px}
.checkbox-item{display:flex;align-items:center;gap:6px;background:var(--bg3);border:1px solid var(--border);border-radius:6px;padding:6px 10px;cursor:pointer;font-size:12px;font-weight:600;transition:all .15s}
.checkbox-item:hover{border-color:var(--border2)}
.checkbox-item input{accent-color:var(--accent)}

/* KEYS MODAL */
.keys-grid{display:grid;gap:8px}
.key-item{background:var(--bg3);border:1px solid var(--border);border-radius:10px;padding:12px;cursor:pointer;transition:all .15s;position:relative}
.key-item:hover{border-color:var(--accent);background:rgba(47,129,247,0.05)}
.key-item:active{transform:scale(0.99)}
.key-label{font-size:10px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:0.5px;margin-bottom:6px;display:flex;align-items:center;gap:6px}
.key-value{font-family:'JetBrains Mono',monospace;font-size:10px;color:var(--text);word-break:break-all;line-height:1.5}
.key-copied{position:absolute;top:8px;right:8px;font-size:10px;color:var(--green);font-weight:700;opacity:0;transition:opacity .2s}
.key-item.copied .key-copied{opacity:1}

/* TRAFFIC */
.traffic-node-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px;margin-bottom:20px}
.traffic-node-card{background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px}
.tncl{font-size:11px;color:var(--muted);font-weight:700;text-transform:uppercase;margin-bottom:8px}
.tncv{font-size:22px;font-weight:800;font-family:'JetBrains Mono',monospace;color:var(--cyan)}
.tncs{display:flex;gap:12px;margin-top:8px;font-size:11px;font-family:'JetBrains Mono',monospace}
.tncs span{color:var(--muted)}
.tncs .up{color:var(--green)}
.tncs .dn{color:var(--accent)}

/* SEARCH */
.search-box{position:relative}
.search-box input{padding-left:32px;background:var(--bg3);border:1px solid var(--border);border-radius:8px;color:var(--text);font-size:13px;font-family:'Syne',sans-serif;outline:none;width:200px;padding-top:7px;padding-bottom:7px;padding-right:12px;transition:all .2s}
.search-box input:focus{border-color:var(--accent);width:240px}
.search-box::before{content:'🔍';position:absolute;left:10px;top:50%;transform:translateY(-50%);font-size:12px;pointer-events:none}

/* TOAST */
.toast{position:fixed;bottom:20px;right:20px;background:var(--bg3);border:1px solid var(--border2);border-radius:10px;padding:12px 16px;font-size:13px;font-weight:600;z-index:9999;transform:translateY(60px);opacity:0;transition:all .3s;max-width:300px}
.toast.show{transform:translateY(0);opacity:1}

/* EMPTY */
.empty{display:flex;flex-direction:column;align-items:center;justify-content:center;padding:48px;color:var(--muted);text-align:center}
.empty-icon{font-size:40px;margin-bottom:12px;opacity:0.5}
.empty-text{font-size:14px;font-weight:600}

/* DASHBOARD SPECIFIC */
.dash-online{display:flex;align-items:center;gap:6px;font-size:12px;color:var(--green);font-weight:700}
.dash-online::before{content:'';width:6px;height:6px;background:var(--green);border-radius:50%;animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1;box-shadow:0 0 0 0 rgba(63,185,80,0.4)}50%{opacity:0.7;box-shadow:0 0 0 4px rgba(63,185,80,0)}}

/* SCROLLBAR */
::-webkit-scrollbar{width:4px;height:4px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:var(--border2);border-radius:2px}

/* LOGIN */
.login-page{display:flex;align-items:center;justify-content:center;min-height:100vh;background:var(--bg)}
.login-card{background:var(--bg2);border:1px solid var(--border);border-radius:16px;padding:32px;width:360px}
.login-logo{text-align:center;margin-bottom:28px}
.login-logo-text{font-size:28px;font-weight:800}
.login-logo-text span{color:var(--accent)}
.login-sub{font-size:12px;color:var(--muted);margin-top:4px}
.login-error{background:rgba(248,81,73,0.1);border:1px solid rgba(248,81,73,0.3);color:var(--red);border-radius:8px;padding:10px 12px;font-size:13px;margin-bottom:14px;display:none}

/* HOSTS */
.host-tag{display:inline-flex;align-items:center;padding:3px 8px;background:var(--bg4);border:1px solid var(--border2);border-radius:4px;font-family:'JetBrains Mono',monospace;font-size:11px;color:var(--accent4)}

/* RESPONSIVE */
@media(max-width:768px){
  .sidebar{width:60px;min-width:60px}
  .ni span:not(.ico){display:none}
  .logo-text,.logo-sub,.nav-section,.user-info{display:none}
  .form-row{grid-template-columns:1fr}
  .stats-grid{grid-template-columns:1fr 1fr}
}
</style>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.0/chart.umd.min.js"></script>
</head>
<body>

<!-- LOGIN -->
<div id="login-screen" class="login-page">
  <div class="login-card">
    <div class="login-logo">
      <div class="login-logo-text">VPN<span>Panel</span></div>
      <div class="login-sub">Панель управления</div>
    </div>
    <div id="login-error" class="login-error">Неверный логин или пароль</div>
    <div class="form-group">
      <label class="form-label">Логин</label>
      <input id="l-user" class="form-input" placeholder="admin" type="text">
    </div>
    <div class="form-group">
      <label class="form-label">Пароль</label>
      <input id="l-pass" class="form-input" placeholder="••••••••" type="password">
    </div>
    <button class="btn btn-primary" style="width:100%;justify-content:center;margin-top:4px" id="btn-login">Войти</button>
  </div>
</div>

<!-- APP -->
<div id="app" class="app" style="display:none">
  <div class="sidebar">
    <div class="logo">
      <div class="logo-text">VPN<span>Panel</span></div>
      <div class="logo-sub">v2.0 · remna-style</div>
    </div>
    <div class="nav">
      <div class="nav-section">Основное</div>
      <div class="ni active" id="nav-dash"><span class="ico">📊</span><span>Дашборд</span></div>
      <div class="ni" id="nav-users"><span class="ico">👥</span><span>Пользователи</span></div>
      <div class="nav-section">Инфраструктура</div>
      <div class="ni" id="nav-inbounds"><span class="ico">⚡</span><span>Inbounds</span></div>
      <div class="ni" id="nav-nodes"><span class="ico">🖥</span><span>Ноды</span></div>
      <div class="ni" id="nav-bridges"><span class="ico">🌉</span><span>Мосты</span></div>
      <div class="ni" id="nav-hosts"><span class="ico">🌐</span><span>Hosts</span></div>
      <div class="nav-section">Система</div>
      <div class="ni" id="nav-traffic"><span class="ico">📈</span><span>Трафик</span></div>
      <div class="ni" id="nav-admins"><span class="ico">👮</span><span>Админы</span></div>
      <div class="ni" id="nav-bots"><span class="ico">🤖</span><span>Боты</span></div>
      <div class="ni" id="nav-audit" onclick="navTo('audit')"><span class="ico">📋</span><span>Лог действий</span></div>
      <div class="ni" id="nav-settings"><span class="ico">⚙️</span><span>Настройки</span></div>
    </div>
    <div class="sidebar-bottom">
      <div class="user-badge">
        <div class="user-avatar" id="sb-avatar">A</div>
        <div class="user-info">
          <div class="user-name" id="sb-name">Admin</div>
          <div class="user-role" id="sb-role">Администратор</div>
        </div>
      </div>
      <div class="ni" id="nav-logout" style="color:var(--red)"><span class="ico">🚪</span><span>Выйти</span></div>
    </div>
  </div>

  <div class="main" id="main-content">
    <!-- DASHBOARD -->
    <div class="page active" id="page-dash">
      <div class="ph">
        <div class="ph-top">
          <div>
            <div class="pt">Дашборд</div>
            <div class="ps">Общая статистика системы</div>
          </div>
          <div class="dash-online" id="dash-online">Онлайн</div>
        </div>
      </div>
      <div class="stats-grid">
        <div class="stat-card blue"><div class="stat-label">Всего пользователей</div><div class="stat-value" id="d-total">0</div><div class="stat-sub">зарегистрировано</div></div>
        <div class="stat-card green"><div class="stat-label">Активных</div><div class="stat-value" id="d-active">0</div><div class="stat-sub">сейчас работают</div></div>
        <div class="stat-card red"><div class="stat-label">Истекло</div><div class="stat-value" id="d-expired">0</div><div class="stat-sub">требуют продления</div></div>
        <div class="stat-card yellow"><div class="stat-label">Превышен лимит</div><div class="stat-value" id="d-overlimit">0</div><div class="stat-sub">исчерпан трафик</div></div>
        <div class="stat-card cyan"><div class="stat-label">Общий трафик</div><div class="stat-value" id="d-traffic">0</div><div class="stat-sub" id="d-traffic-sub">MB использовано</div></div>
        <div class="stat-card purple"><div class="stat-label">Нод онлайн</div><div class="stat-value" id="d-nodes">0</div><div class="stat-sub">серверов активно</div></div>
        <div class="stat-card cyan"><div class="stat-label">Соединений</div><div class="stat-value" id="d-connections">—</div><div class="stat-sub">сейчас онлайн</div></div>
      </div>



      <!-- Bandwidth как remnawave -->
      <div style="margin-bottom:20px">
        <div style="font-size:13px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:1px;margin-bottom:12px">📊 Bandwidth</div>
        <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-bottom:12px">
          <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:20px;display:flex;justify-content:space-between;align-items:center">
            <div>
              <div style="font-size:12px;color:var(--muted);margin-bottom:8px">Today</div>
              <div style="font-size:18px;font-weight:700" id="bw-today">—</div>
              <div style="font-size:11px;margin-top:6px" id="bw-today-vs">vs yesterday</div>
            </div>
            <div style="width:48px;height:48px;background:rgba(88,166,255,0.15);border-radius:12px;display:flex;align-items:center;justify-content:center;font-size:22px">📅</div>
          </div>
          <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:20px;display:flex;justify-content:space-between;align-items:center">
            <div>
              <div style="font-size:12px;color:var(--muted);margin-bottom:8px">Last 7 days</div>
              <div style="font-size:18px;font-weight:700" id="bw-7d">—</div>
              <div style="font-size:11px;margin-top:6px" id="bw-7d-vs">vs last week</div>
            </div>
            <div style="width:48px;height:48px;background:rgba(63,185,80,0.15);border-radius:12px;display:flex;align-items:center;justify-content:center;font-size:22px">📈</div>
          </div>
          <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:20px;display:flex;justify-content:space-between;align-items:center">
            <div>
              <div style="font-size:12px;color:var(--muted);margin-bottom:8px">Last 30 days</div>
              <div style="font-size:18px;font-weight:700" id="bw-30d">—</div>
              <div style="font-size:11px;margin-top:6px" id="bw-30d-vs">vs last month</div>
            </div>
            <div style="width:48px;height:48px;background:rgba(240,165,0,0.15);border-radius:12px;display:flex;align-items:center;justify-content:center;font-size:22px">🗓️</div>
          </div>
        </div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px">
          <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:20px;display:flex;justify-content:space-between;align-items:center">
            <div>
              <div style="font-size:12px;color:var(--muted);margin-bottom:8px">Calendar month</div>
              <div style="font-size:18px;font-weight:700" id="bw-month">—</div>
            </div>
            <div style="width:48px;height:48px;background:rgba(163,113,247,0.15);border-radius:12px;display:flex;align-items:center;justify-content:center;font-size:22px">📆</div>
          </div>
          <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:20px;display:flex;justify-content:space-between;align-items:center">
            <div>
              <div style="font-size:12px;color:var(--muted);margin-bottom:8px">Current year</div>
              <div style="font-size:18px;font-weight:700" id="bw-year">—</div>
            </div>
            <div style="width:48px;height:48px;background:rgba(88,166,255,0.15);border-radius:12px;display:flex;align-items:center;justify-content:center;font-size:22px">🗃️</div>
          </div>
        </div>
      </div>
      <!-- Обзор сервера -->
      <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:20px;margin-bottom:20px">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
          <div style="font-weight:700;font-size:14px">🖥️ Обзор сервера</div>
          <div style="font-size:12px;color:var(--muted)" id="sys-uptime">—</div>
        </div>
        <div style="display:grid;grid-template-columns:repeat(5,1fr);gap:16px;align-items:center">
          <!-- CPU круг -->
          <div style="text-align:center">
            <div style="position:relative;width:80px;height:80px;margin:0 auto">
              <svg width="80" height="80" style="transform:rotate(-90deg)">
                <circle cx="40" cy="40" r="32" fill="none" stroke="var(--border)" stroke-width="6"/>
                <circle id="cpu-circle" cx="40" cy="40" r="32" fill="none" stroke="var(--accent)" stroke-width="6" stroke-dasharray="201" stroke-dashoffset="201" style="transition:stroke-dashoffset 0.5s"/>
              </svg>
              <div style="position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);font-size:13px;font-weight:700" id="sys-cpu">0%</div>
            </div>
            <div style="font-size:11px;color:var(--muted);margin-top:6px">CPU</div>
          </div>
          <!-- RAM круг -->
          <div style="text-align:center">
            <div style="position:relative;width:80px;height:80px;margin:0 auto">
              <svg width="80" height="80" style="transform:rotate(-90deg)">
                <circle cx="40" cy="40" r="32" fill="none" stroke="var(--border)" stroke-width="6"/>
                <circle id="ram-circle" cx="40" cy="40" r="32" fill="none" stroke="var(--cyan)" stroke-width="6" stroke-dasharray="201" stroke-dashoffset="201" style="transition:stroke-dashoffset 0.5s"/>
              </svg>
              <div style="position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);font-size:13px;font-weight:700" id="sys-ram">0%</div>
            </div>
            <div style="font-size:11px;color:var(--muted);margin-top:6px" id="sys-ram-detail">RAM</div>
          </div>
          <!-- Диск круг -->
          <div style="text-align:center">
            <div style="position:relative;width:80px;height:80px;margin:0 auto">
              <svg width="80" height="80" style="transform:rotate(-90deg)">
                <circle cx="40" cy="40" r="32" fill="none" stroke="var(--border)" stroke-width="6"/>
                <circle id="disk-circle" cx="40" cy="40" r="32" fill="none" stroke="#f0a500" stroke-width="6" stroke-dasharray="201" stroke-dashoffset="201" style="transition:stroke-dashoffset 0.5s"/>
              </svg>
              <div style="position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);font-size:13px;font-weight:700" id="sys-disk">0%</div>
            </div>
            <div style="font-size:11px;color:var(--muted);margin-top:6px" id="sys-disk-detail">Диск</div>
          </div>
          <!-- Download -->
          <div style="text-align:center">
            <div style="font-size:22px;font-weight:800;color:#3fb950" id="sys-recv">—</div>
            <div style="font-size:11px;color:var(--muted);margin-top:4px">↓ Download</div>
            <div style="font-size:22px;font-weight:800;color:var(--accent);margin-top:8px" id="sys-sent">—</div>
            <div style="font-size:11px;color:var(--muted);margin-top:4px">↑ Upload</div>
          </div>
          <!-- Аптайм -->
          <div style="text-align:center">
            <div style="font-size:18px;font-weight:800;color:var(--text)" id="sys-uptime2">—</div>
            <div style="font-size:11px;color:var(--muted);margin-top:4px">Аптайм</div>
          </div>
        </div>
      </div>
      <!-- Node status cards -->
      <div class="table-card">
        <div class="table-header">
          <div class="table-title">📡 Состояние серверов</div>
          <button class="btn btn-secondary btn-sm" onclick="loadDash()">🔄 Обновить</button>
        </div>
        <div id="dash-nodes" style="padding:16px;display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:12px"></div>
      </div>

      <!-- Traffic Chart -->
            <!-- Статистика индикаторы -->
      <div style="margin-bottom:20px">
        <div style="font-size:13px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:1px;margin-bottom:12px">📊 Статистика</div>
        <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:12px">
          <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px;display:flex;justify-content:space-between;align-items:center">
            <div>
              <div style="font-size:11px;color:var(--muted);margin-bottom:6px">VLESS трафик</div>
              <div style="font-size:18px;font-weight:700;color:var(--accent)" id="stat-vless">—</div>
              <div style="font-size:11px;color:var(--muted);margin-top:4px">за 7 дней</div>
            </div>
            <div style="width:40px;height:40px;background:rgba(88,166,255,0.15);border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:18px">⚡</div>
          </div>
          <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px;display:flex;justify-content:space-between;align-items:center">
            <div>
              <div style="font-size:11px;color:var(--muted);margin-bottom:6px">Hysteria2 трафик</div>
              <div style="font-size:18px;font-weight:700;color:var(--cyan)" id="stat-hy2">—</div>
              <div style="font-size:11px;color:var(--muted);margin-top:4px">за 7 дней</div>
            </div>
            <div style="width:40px;height:40px;background:rgba(47,222,177,0.15);border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:18px">🚀</div>
          </div>
          <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px;display:flex;justify-content:space-between;align-items:center">
            <div>
              <div style="font-size:11px;color:var(--muted);margin-bottom:6px">Main Server</div>
              <div style="font-size:18px;font-weight:700;color:#3fb950" id="stat-main">—</div>
              <div style="font-size:11px;color:var(--muted);margin-top:4px">за 7 дней</div>
            </div>
            <div style="width:40px;height:40px;background:rgba(63,185,80,0.15);border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:18px">🇸🇪</div>
          </div>
          <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px;display:flex;justify-content:space-between;align-items:center">
            <div>
              <div style="font-size:11px;color:var(--muted);margin-bottom:6px">Russia-75</div>
              <div style="font-size:18px;font-weight:700;color:#f0a500" id="stat-ru75">—</div>
              <div style="font-size:11px;color:var(--muted);margin-top:4px">за 7 дней</div>
            </div>
            <div style="width:40px;height:40px;background:rgba(240,165,0,0.15);border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:18px">🇷🇺</div>
          </div>
          <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px;display:flex;justify-content:space-between;align-items:center">
            <div>
              <div style="font-size:11px;color:var(--muted);margin-bottom:6px">Новых юзеров</div>
              <div style="font-size:18px;font-weight:700;color:var(--accent)" id="stat-new-users">—</div>
              <div style="font-size:11px;color:var(--muted);margin-top:4px">за 7 дней</div>
            </div>
            <div style="width:40px;height:40px;background:rgba(88,166,255,0.15);border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:18px">👤</div>
          </div>
          <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px;display:flex;justify-content:space-between;align-items:center">
            <div>
              <div style="font-size:11px;color:var(--muted);margin-bottom:6px">Активных сегодня</div>
              <div style="font-size:18px;font-weight:700;color:#3fb950" id="stat-active-today">—</div>
              <div style="font-size:11px;color:var(--muted);margin-top:4px">уникальных</div>
            </div>
            <div style="width:40px;height:40px;background:rgba(63,185,80,0.15);border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:18px">✅</div>
          </div>
          <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px;display:flex;justify-content:space-between;align-items:center">
            <div>
              <div style="font-size:11px;color:var(--muted);margin-bottom:6px">↓ Download</div>
              <div style="font-size:18px;font-weight:700;color:var(--cyan)" id="stat-dl">—</div>
              <div style="font-size:11px;color:var(--muted);margin-top:4px">всего</div>
            </div>
            <div style="width:40px;height:40px;background:rgba(47,222,177,0.15);border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:18px">⬇️</div>
          </div>
          <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px;display:flex;justify-content:space-between;align-items:center">
            <div>
              <div style="font-size:11px;color:var(--muted);margin-bottom:6px">↑ Upload</div>
              <div style="font-size:18px;font-weight:700;color:var(--accent)" id="stat-ul">—</div>
              <div style="font-size:11px;color:var(--muted);margin-top:4px">всего</div>
            </div>
            <div style="width:40px;height:40px;background:rgba(88,166,255,0.15);border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:18px">⬆️</div>
          </div>
        </div>
      </div>
<div class="table-card">
        <div class="table-header">
          <div class="table-title">👥 Последние пользователи</div>
        </div>
        <table>
          <thead><tr><th>Пользователь</th><th>Статус</th><th>Трафик</th><th>Истекает</th></tr></thead>
          <tbody id="dash-users-tb"></tbody>
        </table>
      </div>
    </div>

    <!-- USERS -->
    <div class="page" id="page-users">
      <div class="ph">
        <div class="ph-top">
          <div><div class="pt">Пользователи</div><div class="ps">Управление VPN-аккаунтами</div></div>
          <div class="ph-actions">
            <div class="search-box"><input type="text" id="user-search" placeholder="Поиск..."></div>
            <button class="btn btn-primary" id="btn-add-user">+ Добавить</button>
          </div>
        </div>
      </div>
      <div class="table-card">
        <table>
          <thead><tr><th>Пользователь</th><th>Статус</th><th>Трафик</th><th>Истекает</th><th>Действия</th></tr></thead>
          <tbody id="users-tb"></tbody>
        </table>
      </div>
    </div>

    <!-- NODES -->
    <div class="page" id="page-nodes">
      <div class="ph">
        <div class="ph-top">
          <div><div class="pt">Ноды</div><div class="ps">VPN серверы</div></div>
          <button class="btn btn-primary" id="btn-add-node">+ Добавить</button>
        </div>
      </div>
      <div class="nodes-grid" id="nodes-grid"></div>
    </div>

    <!-- BRIDGES -->
    <div class="page" id="page-bridges">
      <div class="ph">
        <div class="ph-top">
          <div><div class="pt">Мосты</div><div class="ps">Туннелирование трафика</div></div>
          <button class="btn btn-primary" id="btn-add-bridge">+ Создать мост</button>
        </div>
      </div>
      <div class="table-card">
        <table>
          <thead><tr><th>Нода</th><th>RU IP</th><th>Foreign IP</th><th>Статус</th><th>Создан</th><th></th></tr></thead>
          <tbody id="bridges-tb"></tbody>
        </table>
      </div>
    </div>

    <!-- HOSTS -->
    <div class="page" id="page-hosts">
      <div class="ph">
        <div class="ph-top">
          <div><div class="pt">Hosts</div><div class="ps">Глобальные настройки хостов для всех пользователей</div></div>
          <div class="ph-actions">
            <button class="btn btn-success btn-sm" id="btn-regen-all">🔄 Перегенерировать ключи</button>
            <button class="btn btn-primary" id="btn-add-host">+ Добавить</button>
          </div>
        </div>
      </div>
      <div style="background:rgba(227,179,65,0.08);border:1px solid rgba(227,179,65,0.3);border-radius:10px;padding:12px 16px;margin-bottom:20px;font-size:13px;color:var(--yellow);display:flex;align-items:center;gap:8px">
        ⚠️ Изменение хоста автоматически обновит ключи <b>всех пользователей</b>
      </div>
      <div class="table-card">
        <table>
          <thead><tr><th>Inbound</th><th>Название</th><th>Адрес</th><th>Порт</th><th>SNI</th><th>Статус</th><th></th></tr></thead>
          <tbody id="hosts-tb"></tbody>
        </table>
      </div>
    </div>

    <!-- TRAFFIC -->
    <div class="page" id="page-traffic">
      <div class="ph">
        <div class="ph-top">
          <div><div class="pt">Трафик</div><div class="ps">Мониторинг использования</div></div>
          <button class="btn btn-secondary btn-sm" onclick="loadTraffic()">🔄 Обновить</button>
        </div>
      </div>
      <div class="stats-grid" style="grid-template-columns:repeat(3,1fr)">
        <div class="stat-card cyan"><div class="stat-label">Общий трафик</div><div class="stat-value" id="tr-total">—</div></div>
        <div class="stat-card red"><div class="stat-label">Истекло</div><div class="stat-value" id="tr-expired">—</div></div>
        <div class="stat-card yellow"><div class="stat-label">Превышен лимит</div><div class="stat-value" id="tr-overlimit">—</div></div>
      </div>
      <div class="traffic-node-grid" id="node-traffic-grid"></div>
      <div class="table-card">
        <div class="table-header"><div class="table-title">👥 По пользователям</div></div>
        <table>
          <thead><tr><th>Пользователь</th><th>Использовано</th><th>Лимит</th><th>Прогресс</th><th>Статус</th><th>Истекает</th></tr></thead>
          <tbody id="traffic-tb"></tbody>
        </table>
      </div>
    </div>

    <!-- ADMINS -->
    <div class="page" id="page-admins">
      <div class="ph">
        <div class="ph-top">
          <div><div class="pt">Администраторы</div><div class="ps">Управление доступом</div></div>
          <button class="btn btn-primary" id="btn-add-admin">+ Добавить</button>
        </div>
      </div>
      <div class="table-card">
        <table>
          <thead><tr><th>Логин</th><th>Права</th><th>Создан</th><th></th></tr></thead>
          <tbody id="admins-tb"></tbody>
        </table>
      </div>
    </div>

    <!-- BOTS -->
    <div class="page" id="page-bots">
      <div class="ph">
        <div class="ph-top">
          <div><div class="pt">Боты</div><div class="ps">API токены для Telegram ботов</div></div>
          <button class="btn btn-primary" id="btn-add-bot">+ Создать токен</button>
        </div>
      </div>
      <div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px;margin-bottom:20px;font-size:12px;font-family:'JetBrains Mono',monospace">
        <div style="color:var(--muted);margin-bottom:8px;font-family:'Syne',sans-serif;font-size:13px;font-weight:700">Использование API</div>
        <div style="color:var(--accent4)">POST /bot/users/create</div>
        <div style="color:var(--muted);margin:4px 0">Headers: X-Bot-Token: &lt;token&gt;</div>
        <div style="color:var(--muted)">Body: {"username":"...", "expire_days":30, "data_limit_mb":10}</div>
      </div>
      <div class="table-card">
        <table>
          <thead><tr><th>Название</th><th>Создан</th><th></th></tr></thead>
          <tbody id="bots-tb"></tbody>
        </table>
      </div>
    </div>

    <div class="page" id="page-audit">
  <div class="page-header">
    <div>
      <div class="page-title">Лог действий</div>
      <div class="page-sub">История всех операций в панели</div>
    </div>
    <button class="btn btn-secondary btn-sm" id="btn-audit-refresh">🔄 Обновить</button>
  </div>
  <div id="audit-page-list"></div>

  <div style="margin-top:24px">
    <div style="font-size:13px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:1px;margin-bottom:12px">🤖 Авто-диагностика</div>
    <div id="autodiag-log" style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px;font-family:monospace;font-size:12px;max-height:300px;overflow-y:auto"></div>
  </div>
</div>


    <!-- INBOUNDS -->
    <div class="page" id="page-inbounds">
      <div class="page-header">
        <div class="page-title">⚡ Inbounds</div>
        <button class="btn btn-primary" onclick="openModal('modal-inbound-add')">➕ Добавить</button>
      </div>
      <div id="inbounds-grid" style="display:grid;gap:16px;grid-template-columns:repeat(auto-fill,minmax(380px,1fr))"></div>
    </div>

    <!-- SETTINGS -->
    <div class="page" id="page-settings">
      <div class="ph">
        <div class="ph-top">
          <div><div class="pt">Настройки</div><div class="ps">Конфигурация панели</div></div>
          <div class="settings-section">
        <div class="settings-title">🔄 Автопродление подписок</div>
        <div class="form-row">
          <div class="form-group">
            <label class="form-label">Автопродление</label>
            <select id="s-auto-extend" class="form-input">
              <option value="0">Выключено</option>
              <option value="1">Включено</option>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Дней продления</label>
            <input id="s-auto-days" class="form-input" type="number" value="30">
          </div>
        </div>
        <div style="font-size:12px;color:var(--muted)">⚠️ Продлевает только пользователей с включённым auto_extend</div>
      </div>
      <div class="settings-divider"></div>

      <div class="settings-section">
        <div class="settings-title">🔗 Webhook уведомления</div>
        <div class="form-group">
          <label class="form-label">URL для уведомлений</label>
          <input id="s-webhook-url" class="form-input" placeholder="https://yoursite.com/webhook">
        </div>
        <div class="form-group">
          <label class="form-label">Секретный ключ (для подписи)</label>
          <input id="s-webhook-secret" class="form-input" placeholder="my-secret-key">
        </div>
        <div class="form-group">
          <label class="form-label">События</label>
          <div style="display:flex;gap:12px;flex-wrap:wrap;margin-top:8px">
            <label style="display:flex;align-items:center;gap:6px;font-size:13px"><input type="checkbox" id="wh-expired" checked> Истёк пользователь</label>
            <label style="display:flex;align-items:center;gap:6px;font-size:13px"><input type="checkbox" id="wh-node" checked> Нода упала</label>
            <label style="display:flex;align-items:center;gap:6px;font-size:13px"><input type="checkbox" id="wh-overlimit" checked> Превышен лимит</label>
            <label style="display:flex;align-items:center;gap:6px;font-size:13px"><input type="checkbox" id="wh-created"> Создан пользователь</label>
          </div>
        </div>
        <button class="btn btn-secondary btn-sm" id="btn-test-webhook">📤 Тест Webhook</button>
      </div>
      <div class="settings-divider"></div>

      <button class="btn btn-primary" id="btn-save-settings">💾 Сохранить</button>
        </div>
      </div>

      <!-- Telegram -->
      <div class="table-card" style="margin-bottom:20px">
        <div class="table-header"><div class="table-title">📱 Telegram уведомления</div></div>
        <div style="padding:16px;display:grid;grid-template-columns:1fr 1fr;gap:12px">
          <div class="form-group"><label class="form-label">Bot Token</label><input id="s-tg-token" class="form-input" placeholder="1234567890:AABBcc..."></div>
          <div class="form-group"><label class="form-label">Admin ID</label><input id="s-tg-admin" class="form-input" placeholder="123456789"></div>
          <div class="form-group"><label class="form-label">Домен панели</label><input id="s-domain" class="form-input" placeholder="https://panel.example.com"></div>
          <div class="form-group"><label class="form-label">Домен подписок</label><input id="s-sub-domain" class="form-input" placeholder="https://sub.example.com"></div>
        </div>
        <div style="padding:0 16px 16px;display:flex;gap:12px">
          <label class="checkbox-item"><input type="checkbox" id="s-tg-nodes" checked> Уведомления о нодах</label>
          <label class="checkbox-item"><input type="checkbox" id="s-tg-users" checked> Уведомления о пользователях</label>
        </div>
        <div style="padding:0 16px 16px">
          <button class="btn btn-secondary btn-sm" id="btn-test-tg">📤 Тест уведомления</button>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- SETTINGS PAGE (inside main) -->


<!-- MODALS -->
<!-- Add User -->
<div class="modal-overlay" id="modal-add-user">
  <div class="modal">
    <div class="modal-header">
      <div class="modal-title">➕ Новый пользователь</div>
      <div class="modal-close" onclick="closeModal('modal-add-user')">×</div>
    </div>
    <div class="modal-body">
      <div class="form-group"><label class="form-label">Имя пользователя</label><input id="u-username" class="form-input" placeholder="user123"></div>
      <div class="form-group"><label class="form-label">Telegram ID</label><input id="u-tgid" class="form-input" placeholder="123456789" type="number"></div>
      <div class="form-row">
        <div class="form-group"><label class="form-label">Дней</label><input id="u-days" class="form-input" value="30" type="number"></div>
        <div class="form-group"><label class="form-label">Лимит (MB, 0=∞)</label><input id="u-limit" class="form-input" value="0" type="number"></div>
      </div>
      <div class="form-group"><label class="form-label">Заметка</label><input id="u-note" class="form-input" placeholder="Необязательно"></div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-add-user')">Отмена</button>
      <button class="btn btn-primary" id="btn-submit-user">Создать</button>
    </div>
  </div>
</div>

<!-- Keys Modal -->
<div class="modal-overlay" id="modal-keys">
  <div class="modal wide">
    <div class="modal-header">
      <div class="modal-title">🔑 Ключи — <span id="keys-username"></span></div>
      <div class="modal-close" onclick="closeModal('modal-keys')">×</div>
    </div>
    <div class="modal-body">
      <div style="display:flex;gap:8px;margin-bottom:12px">
        <button class="btn btn-secondary btn-sm" onclick="copyAllKeys()">📋 Скопировать все</button>
      </div>

      <div class="keys-grid" id="keys-grid"></div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-keys')">Закрыть</button>
    </div>
  </div>
</div>

<!-- Add Node -->
<div class="modal-overlay" id="modal-add-node">
  <div class="modal">
    <div class="modal-header">
      <div class="modal-title">🖥 Добавить ноду</div>
      <div class="modal-close" onclick="closeModal('modal-add-node')">×</div>
    </div>
    <div class="modal-body">
      <div class="form-group"><label class="form-label">ID ноды</label><input id="n-id" class="form-input" placeholder="node1"></div>
      <div class="form-group"><label class="form-label">Название</label><input id="n-name" class="form-input" placeholder="Sweden-01"></div>
      <div class="form-row">
        <div class="form-group"><label class="form-label">IP адрес</label><input id="n-ip" class="form-input" placeholder="1.2.3.4"></div>
        <div class="form-group"><label class="form-label">Страна</label><input id="n-country" class="form-input" placeholder="SE"></div>
      </div>
      <div class="form-row">
        <div class="form-group"><label class="form-label">SSH порт</label><input id="n-ssh-port" class="form-input" value="22" type="number"></div>
        <div class="form-group"><label class="form-label">SSH пользователь</label><input id="n-ssh-user" class="form-input" value="root"></div>
      </div>
      <div class="form-group"><label class="form-label">SSH пароль</label><input id="n-ssh-pass" class="form-input" type="password"></div>
      <div class="checkbox-item" style="margin-top:4px"><input type="checkbox" id="n-auto" checked><label for="n-auto">Автоустановка sing-box</label></div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-add-node')">Отмена</button>
      <button class="btn btn-primary" id="btn-submit-node">🚀 Добавить</button>
    </div>
  </div>
</div>

<!-- Add Bridge -->
<div class="modal-overlay" id="modal-add-bridge">
  <div class="modal">
    <div class="modal-header">
      <div class="modal-title">🌉 Создать мост</div>
      <div class="modal-close" onclick="closeModal('modal-add-bridge')">×</div>
    </div>
    <div class="modal-body">
      <div style="font-size:12px;font-weight:700;color:var(--muted);text-transform:uppercase;margin-bottom:12px">🇷🇺 Russian нода (входящий трафик)</div>
      <div class="form-group"><label class="form-label">Выберите RU ноду</label><select id="b-ru-node" class="form-input"></select></div>
      <div style="font-size:12px;font-weight:700;color:var(--muted);text-transform:uppercase;margin:16px 0 12px">🌍 Foreign нода (выходной трафик)</div>
      <div class="form-group"><label class="form-label">Выберите Foreign ноду</label><select id="b-foreign-node" class="form-input"></select></div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-add-bridge')">Отмена</button>
      <button class="btn btn-primary" id="btn-submit-bridge">🌉 Создать</button>
    </div>
  </div>
</div>

<!-- Host Edit Modal -->
<div class="modal-overlay" id="modal-host-edit">
  <div class="modal">
    <div class="modal-header">
      <div class="modal-title">✏️ Редактировать хост</div>
      <div class="modal-close" onclick="closeModal('modal-host-edit')">×</div>
    </div>
    <div class="modal-body">
      <input type="hidden" id="edit-host-id">
      <div class="form-group"><label class="form-label">Название</label><input id="edit-host-remark" class="form-input" placeholder="Main VLESS"></div>
      <div class="form-group"><label class="form-label">Адрес</label><input id="edit-host-address" class="form-input" placeholder="193.168.197.161"></div>
      <div class="form-row">
        <div class="form-group"><label class="form-label">Порт</label><input id="edit-host-port" class="form-input" type="number"></div>
        <div class="form-group"><label class="form-label">SNI</label><input id="edit-host-sni" class="form-input"></div>
      </div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-host-edit')">Отмена</button>
      <button class="btn btn-primary" id="btn-save-host">💾 Сохранить</button>
    </div>
  </div>
</div>

<!-- Host Add Modal -->
<div class="modal-overlay" id="modal-host-add">
  <div class="modal">
    <div class="modal-header">
      <div class="modal-title">➕ Добавить хост</div>
      <div class="modal-close" onclick="closeModal('modal-host-add')">×</div>
    </div>
    <div class="modal-body">
      <div class="form-group"><label class="form-label">Inbound тег</label>
        <select id="add-host-tag" class="form-select">
          <option value="vless-main">vless-main</option>
          <option value="hy2-main">hy2-main</option>
          <option value="vless-bridge">vless-bridge</option>
          <option value="hy2-bridge">hy2-bridge</option>
          <option value="vless-ru75">vless-ru75</option>
          <option value="hy2-ru75">hy2-ru75</option>
        </select>
      </div>
      <div class="form-group"><label class="form-label">Название</label><input id="add-host-remark" class="form-input" placeholder="My Host"></div>
      <div class="form-group"><label class="form-label">Адрес</label><input id="add-host-address" class="form-input" placeholder="1.2.3.4"></div>
      <div class="form-row">
        <div class="form-group"><label class="form-label">Порт</label><input id="add-host-port" class="form-input" type="number" value="443"></div>
        <div class="form-group"><label class="form-label">SNI</label><input id="add-host-sni" class="form-input" placeholder="www.microsoft.com"></div>
      </div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-host-add')">Отмена</button>
      <button class="btn btn-primary" id="btn-submit-host-add">➕ Добавить</button>
    </div>
  </div>
</div>

<!-- Add Admin -->
<div class="modal-overlay" id="modal-add-admin">
  <div class="modal">
    <div class="modal-header">
      <div class="modal-title">👮 Добавить администратора</div>
      <div class="modal-close" onclick="closeModal('modal-add-admin')">×</div>
    </div>
    <div class="modal-body">
      <div class="form-row">
        <div class="form-group"><label class="form-label">Логин</label><input id="a-username" class="form-input" placeholder="subadmin"></div>
        <div class="form-group"><label class="form-label">Пароль</label><input id="a-password" class="form-input" type="password"></div>
      </div>
      <div class="form-group"><label class="form-label">Права</label>
        <div class="checkbox-group">
          <label class="checkbox-item"><input type="checkbox" id="a-add" checked> Добавлять</label>
          <label class="checkbox-item"><input type="checkbox" id="a-del" checked> Удалять</label>
          <label class="checkbox-item"><input type="checkbox" id="a-toggle" checked> Вкл/Выкл</label>
          <label class="checkbox-item"><input type="checkbox" id="a-keys" checked> Ключи</label>
          <label class="checkbox-item"><input type="checkbox" id="a-nodes"> Ноды</label>
          <label class="checkbox-item"><input type="checkbox" id="a-bridges"> Мосты</label>
        </div>
      </div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-add-admin')">Отмена</button>
      <button class="btn btn-primary" id="btn-submit-admin">Создать</button>
    </div>
  </div>
</div>

<!-- Add Bot -->
<div class="modal-overlay" id="modal-add-bot">
  <div class="modal">
    <div class="modal-header">
      <div class="modal-title">🤖 Новый бот</div>
      <div class="modal-close" onclick="closeModal('modal-add-bot')">×</div>
    </div>
    <div class="modal-body">
      <div class="form-group"><label class="form-label">Название бота</label><input id="bot-name" class="form-input" placeholder="SalesBot"></div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-add-bot')">Отмена</button>
      <button class="btn btn-primary" id="btn-submit-bot">Создать</button>
    </div>
  </div>
</div>

<!-- Bot Token Display -->
<div class="modal-overlay" id="modal-bot-token">
  <div class="modal">
    <div class="modal-header">
      <div class="modal-title">🔐 Токен создан</div>
      <div class="modal-close" onclick="closeModal('modal-bot-token')">×</div>
    </div>
    <div class="modal-body">
      <div style="background:rgba(63,185,80,0.08);border:1px solid rgba(63,185,80,0.2);border-radius:8px;padding:12px;margin-bottom:12px;font-size:12px;color:var(--green)">
        ⚠️ Сохраните токен — он показывается только один раз!
      </div>
      <div class="key-item" id="bot-token-display" onclick="copyText(document.getElementById('bot-token-val').textContent);toast('✅ Скопировано!')">
        <div class="key-label">🤖 Bot Token</div>
        <div class="key-value" id="bot-token-val"></div>
        <div class="key-copied">✓ Скопировано</div>
      </div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-bot-token')">Закрыть</button>
      <button class="btn btn-primary" onclick="copyText(document.getElementById('bot-token-val').textContent);toast('✅ Скопировано!')">📋 Копировать</button>
    </div>
  </div>
</div>

<!-- Extend Modal -->
<div class="modal-overlay" id="modal-extend">
  <div class="modal">
    <div class="modal-header">
      <div class="modal-title">⏱ Продление подписки</div>
      <div class="modal-close" onclick="closeModal('modal-extend')">×</div>
    </div>
    <div class="modal-body">
      <div style="font-size:13px;color:var(--muted);margin-bottom:16px">Пользователь: <b id="extend-username"></b></div>
      <input type="hidden" id="extend-uid">
      <div class="form-group"><label class="form-label">Дней добавить</label>
        <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-bottom:12px">
          <button class="btn btn-secondary" onclick="document.getElementById('extend-days').value=7">+7</button>
          <button class="btn btn-secondary" onclick="document.getElementById('extend-days').value=14">+14</button>
          <button class="btn btn-secondary" onclick="document.getElementById('extend-days').value=30">+30</button>
          <button class="btn btn-secondary" onclick="document.getElementById('extend-days').value=90">+90</button>
        </div>
        <input id="extend-days" class="form-input" type="number" value="30" placeholder="Дней">
      </div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-extend')">Отмена</button>
      <button class="btn btn-primary" id="btn-submit-extend">✅ Продлить</button>
    </div>
  </div>
</div>

<!-- Note Edit Modal -->
<div class="modal-overlay" id="modal-note">
  <div class="modal">
    <div class="modal-header">
      <div class="modal-title">📝 Заметка</div>
      <div class="modal-close" onclick="closeModal('modal-note')">×</div>
    </div>
    <div class="modal-body">
      <input type="hidden" id="note-uid">
      <div class="form-group">
        <label class="form-label">Заметка для <b id="note-username"></b></label>
        <input id="note-text" class="form-input" placeholder="Введите заметку...">
      </div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-note')">Отмена</button>
      <button class="btn btn-primary" id="btn-save-note">💾 Сохранить</button>
    </div>
  </div>
</div>


<!-- Import Modal -->
<div class="modal-overlay" id="modal-import">
  <div class="modal">
    <div class="modal-header">
      <div class="modal-title">📤 Импорт пользователей CSV</div>
      <div class="modal-close" onclick="closeModal('modal-import')">×</div>
    </div>
    <div class="modal-body">
      <div style="font-size:12px;color:var(--muted);margin-bottom:12px">
        Формат CSV: username, data_limit_mb, note<br>
        Пример: user1, 10, клиент
      </div>
      <input type="file" id="import-file" accept=".csv" class="form-input">
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-import')">Отмена</button>
      <button class="btn btn-primary" onclick="importUsers()">📤 Импортировать</button>
    </div>
  </div>
</div>

<!-- Templates Modal -->
<div class="modal-overlay" id="modal-templates">
  <div class="modal wide">
    <div class="modal-header">
      <div class="modal-title">📋 Шаблоны пользователей</div>
      <div class="modal-close" onclick="closeModal('modal-templates')">×</div>
    </div>
    <div class="modal-body">
      <div id="templates-list" style="display:grid;gap:8px;margin-bottom:16px"></div>
      <div style="border-top:1px solid var(--border);padding-top:16px">
        <div style="font-size:12px;font-weight:700;color:var(--muted);margin-bottom:8px">НОВЫЙ ШАБЛОН</div>
        <div class="form-row">
          <div class="form-group"><label class="form-label">Название</label><input id="tpl-name" class="form-input" placeholder="Базовый"></div>
          <div class="form-group"><label class="form-label">Дней</label><input id="tpl-days" class="form-input" type="number" value="30"></div>
        </div>
        <div class="form-row">
          <div class="form-group"><label class="form-label">Лимит GB (0=∞)</label><input id="tpl-limit" class="form-input" type="number" value="0"></div>
          <div class="form-group"><label class="form-label">Заметка</label><input id="tpl-note" class="form-input" placeholder="..."></div>
        </div>
        <button class="btn btn-primary btn-sm" onclick="createTemplate()">➕ Создать шаблон</button>
      </div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-templates')">Закрыть</button>
    </div>
  </div>
</div>

<!-- Audit Log Modal -->
<div class="modal-overlay" id="modal-audit">
  <div class="modal wide">
    <div class="modal-header">
      <div class="modal-title">📋 Лог действий</div>
      <div class="modal-close" onclick="closeModal('modal-audit')">×</div>
    </div>
    <div class="modal-body">
      <div id="audit-list"></div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-audit')">Закрыть</button>
    </div>
  </div>
</div>


<!-- Edit Inbound Modal -->
<div class="modal-overlay" id="modal-inbound-edit">
  <div class="modal wide">
    <div class="modal-header">
      <div class="modal-title">✏️ Редактировать Inbound</div>
      <div class="modal-close" onclick="closeModal('modal-inbound-edit')">×</div>
    </div>
    <div class="modal-body">
      <input type="hidden" id="edit-ib-tag">
      <div class="form-row">
        <div class="form-group">
          <label class="form-label">Tag</label>
          <input id="edit-ib-name" class="form-input" placeholder="vless-in">
        </div>
        <div class="form-group">
          <label class="form-label">Порт</label>
          <input id="edit-ib-port" class="form-input" type="number" placeholder="443">
        </div>
      </div>
      <div class="form-row">
        <div class="form-group">
          <label class="form-label">Listen</label>
          <input id="edit-ib-listen" class="form-input" value="::" placeholder="::">
        </div>
        <div class="form-group">
          <label class="form-label">Домен (SNI)</label>
          <input id="edit-ib-sni" class="form-input" placeholder="www.microsoft.com">
        </div>
      </div>
      <div id="edit-ib-reality-section">
        <div style="font-size:12px;font-weight:700;color:var(--muted);margin-bottom:8px">REALITY НАСТРОЙКИ</div>
        <div class="form-row">
          <div class="form-group">
            <label class="form-label">Handshake Server</label>
            <input id="edit-ib-hs-server" class="form-input" placeholder="www.microsoft.com">
          </div>
          <div class="form-group">
            <label class="form-label">Handshake Port</label>
            <input id="edit-ib-hs-port" class="form-input" type="number" value="443">
          </div>
        </div>
        <div class="form-row">
          <div class="form-group">
            <label class="form-label">Short ID</label>
            <input id="edit-ib-shortid" class="form-input" placeholder="6128f6b42d261a39">
          </div>
          <div class="form-group">
            <label class="form-label">Private Key</label>
            <input id="edit-ib-privkey" class="form-input" placeholder="...">
          </div>
        </div>
      </div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-inbound-edit')">Отмена</button>
      <button class="btn btn-primary" id="btn-save-inbound">💾 Сохранить</button>
    </div>
  </div>
</div>

<!-- Add Inbound Modal -->
<div class="modal-overlay" id="modal-inbound-add">
  <div class="modal wide">
    <div class="modal-header">
      <div class="modal-title">➕ Новый Inbound</div>
      <div class="modal-close" onclick="closeModal('modal-inbound-add')">×</div>
    </div>
    <div class="modal-body">
      <div class="form-row">
        <div class="form-group">
          <label class="form-label">Тип</label>
          <select id="add-ib-type" class="form-input">
            <option value="vless">VLESS</option>
            <option value="hysteria2">Hysteria2</option>
          </select>
        </div>
        <div class="form-group">
          <label class="form-label">Tag</label>
          <input id="add-ib-tag" class="form-input" placeholder="vless-in-2">
        </div>
      </div>
      <div class="form-row">
        <div class="form-group">
          <label class="form-label">Порт</label>
          <input id="add-ib-port" class="form-input" type="number" placeholder="443">
        </div>
        <div class="form-group">
          <label class="form-label">SNI домен</label>
          <input id="add-ib-sni" class="form-input" placeholder="www.microsoft.com">
        </div>
      </div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-inbound-add')">Отмена</button>
      <button class="btn btn-primary" id="btn-create-inbound">🚀 Создать</button>
    </div>
  </div>
</div>


<div class="modal-overlay" id="modal-change-pass">
  <div class="modal">
    <div class="modal-header">
      <div class="modal-title">🔐 Смена пароля — <span id="cp-username"></span></div>
      <div class="modal-close" onclick="closeModal('modal-change-pass')">×</div>
    </div>
    <div class="modal-body">
      <input type="hidden" id="cp-admin-id">
      <div class="form-group">
        <label class="form-label">Новый пароль</label>
        <input id="cp-new-pass" class="form-input" type="password" placeholder="••••••••">
      </div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-secondary" onclick="closeModal('modal-change-pass')">Отмена</button>
      <button class="btn btn-primary" id="btn-save-pass">💾 Сохранить</button>
    </div>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
(function(){
var TOKEN = localStorage.getItem('vpn_token') || '';
var ROLE = localStorage.getItem('vpn_role') || 'admin';
var _users = [];

function toast(msg, dur) {
  var t = document.getElementById('toast');
  t.textContent = msg;
  t.classList.add('show');
  setTimeout(function(){ t.classList.remove('show'); }, dur||2500);
}

function copyText(txt) {
  try {
    navigator.clipboard.writeText(txt);
  } catch(e) {
    var ta = document.createElement('textarea');
    ta.value = txt;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
  }
}

// Глобальный доступ — объявляем сразу
window.toast = function(m,d){ toast(m,d); };
window.copyText = function(t){ copyText(t); };
window.copyAllKeys = function(){ copyAllKeys(); };
window.showKeys = function(u){ showKeys(u); };
window.openModal = function(id){ openModal(id); };
window.closeModal = function(id){ closeModal(id); };

function fmtBytes(b) {
  if(!b) return '0 MB';
  if(b >= 1073741824) return (b/1073741824).toFixed(2)+' GB';
  return (b/1048576).toFixed(1)+' MB';
}

function fmtDate(ts) {
  if(!ts) return '∞';
  return new Date(ts*1000).toLocaleDateString('ru');
}

function openModal(id) {
  document.getElementById(id).classList.add('open');
}
function closeModal(id) {
  document.getElementById(id).classList.remove('open');
}

document.querySelectorAll('.modal-overlay').forEach(function(o){
  o.addEventListener('click', function(e){
    if(e.target === o) o.classList.remove('open');
  });
});

function api(method, path, body) {
  var opts = {
    method: method,
    headers: {'Authorization':'Bearer '+TOKEN, 'Content-Type':'application/json'}
  };
  if(body) opts.body = JSON.stringify(body);
  return fetch('/api'+path, opts).then(function(r){
    if(r.status === 401){ logout(); return null; }
    return r.json();
  }).catch(function(){ return null; });
}

function logout() {
  localStorage.removeItem('vpn_token');
  localStorage.removeItem('vpn_role');
  localStorage.removeItem('vpn_username');
  TOKEN = '';
  document.getElementById('app').style.display = 'none';
  document.getElementById('login-screen').style.display = 'flex';
}

var pages = ['dash','users','nodes','bridges','hosts','traffic','admins','bots','settings','inbounds','audit'];
function initApp() {
  document.getElementById('login-screen').style.display = 'none';
  document.getElementById('app').style.display = 'flex';
  var name = localStorage.getItem('vpn_username') || 'Admin';
  document.getElementById('sb-name').textContent = name;
  document.getElementById('sb-avatar').textContent = name[0].toUpperCase();
  document.getElementById('sb-role').textContent = ROLE==='admin'?'Администратор':'Субадмин';
  navTo('dash');
}

if(TOKEN) initApp();

document.getElementById('btn-login').onclick = function(){
  var u = document.getElementById('l-user').value.trim();
  var p = document.getElementById('l-pass').value.trim();
  fetch('/api/login',{
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({username:u,password:p})
  }).then(function(r){ return r.json(); }).then(function(d){
    if(d && d.token){
      TOKEN = d.token;
      ROLE = d.role||'admin';
      localStorage.setItem('vpn_token', TOKEN);
      localStorage.setItem('vpn_role', ROLE);
      localStorage.setItem('vpn_username', u);
      document.getElementById('login-error').style.display = 'none';
      initApp();
    } else {
      document.getElementById('login-error').style.display = 'block';
    }
  });
};

document.getElementById('l-pass').onkeydown = function(e){
  if(e.key==='Enter') document.getElementById('btn-login').click();
};
document.getElementById('nav-logout').onclick = logout;


function navTo(name) {
  pages.forEach(function(p){
    var pg = document.getElementById('page-'+p);
    var ni = document.getElementById('nav-'+p);
    if(pg) pg.classList.toggle('active', p===name);
    if(ni) ni.classList.toggle('active', p===name);
  });
  var loaders = {
    dash:loadDash, users:loadUsers, nodes:loadNodes,
    bridges:loadBridges, hosts:loadHosts, traffic:loadTraffic,
    admins:loadAdmins, bots:loadBots, settings:loadSettingsPage, inbounds:loadInbounds, audit:loadAuditPage
  };
  if(loaders[name]) loaders[name]();
}

pages.forEach(function(p){
  var ni = document.getElementById('nav-'+p);
  if(ni) ni.onclick = function(){ navTo(p); };
});

// DASHBOARD
function loadDash() {
  api('GET','/stats').then(function(s){
    if(!s) return;
    document.getElementById('d-total').textContent = s.total_users||0;
    document.getElementById('d-active').textContent = s.active_users||0;
    document.getElementById('d-expired').textContent = s.expired_users||0;
    document.getElementById('d-overlimit').textContent = s.overlimit_users||0;
  });
  api('GET','/traffic/stats').then(function(s){
    if(!s) return;
    var tb = fmtBytes(s.total_traffic_bytes||0).split(' ');
    document.getElementById('d-traffic').textContent = tb[0];
    document.getElementById('d-traffic-sub').textContent = (tb[1]||'MB')+' использовано';
  });
  api('GET','/nodes').then(function(nodes){
    if(!nodes) return;
    var online = nodes.filter(function(n){ return n.status==='online'; }).length;
    document.getElementById('d-nodes').textContent = online+'/'+nodes.length;
    var html = '';
    nodes.forEach(function(n){
      var on = n.status==='online' || n.id==='ru75' || (n.country||'').includes('Russia');
      var ip = n.ip||n.host||'—';
      html += '<div style="background:var(--bg3);border:1px solid '+(on?'rgba(63,185,80,0.3)':'var(--border)')+';border-radius:10px;padding:14px">';
      html += '<div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:10px">';
      html += '<div style="font-weight:700">' + n.name + '</div>';
      html += '<span class="badge '+(on?'badge-green':'badge-red')+'">'+(on?'Online':'Offline')+'</span></div>';
      html += '<div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;font-size:12px">';
      html += '<div style="color:var(--muted)">IP:</div><div class="mono">'+ip+'</div>';
      html += '<div style="color:var(--muted)">Страна:</div><div>'+n.country+'</div>';
      html += '</div></div>';
    });
    document.getElementById('dash-nodes').innerHTML = html||'<div class="empty"><div class="empty-icon">📡</div><div class="empty-text">Нет нод</div></div>';
  });
  api('GET','/users').then(function(users){
    if(!users||!users.length) return;
    var html = '';
    users.slice(0,5).forEach(function(u){
      html += '<tr>';
      html += '<td><b>'+u.username+'</b></td>';
      html += '<td><span class="badge '+(u.status==='active'?'badge-green':u.status==='expired'?'badge-red':'badge-yellow')+'">'+u.status+'</span></td>';
      html += '<td class="mono">'+fmtBytes(u.data_used||0)+' / '+(u.data_limit?fmtBytes(u.data_limit):'∞')+'</td>';
      html += '<td>'+fmtDate(u.expire_at)+'</td>';
      html += '</tr>';
    });
    document.getElementById('dash-users-tb').innerHTML = html;
  });
  loadSysStats();
  loadBandwidth();
  loadDashStats();
  loadChart('traffic', 7);
  // Загружаем активные соединения
  api('GET','/connections/count').then(function(r){
    if(r && r.count !== undefined){
      document.getElementById('d-connections').textContent = r.unique_users || 0;
    }
  });
}

// USERS
function loadUsers() {
  api('GET','/users').then(function(users){
    _users = users||[];
    renderUsers(_users);
  });
}

function renderUsers(users) {
  // Обновляем активные IP
  api('GET','/connections/count').then(function(r){
    if(!r) return;
    window._activeConns = r;
    // Распределяем по активным пользователям
    window._activeIPs = {};
    users.filter(function(u){return u.status==='active';}).forEach(function(u){
      window._activeIPs[u.id] = r.unique_users;
    });
  });
  var tb = document.getElementById('users-tb');
  if(!users||!users.length){
    tb.innerHTML = '<tr><td colspan="5"><div class="empty"><div class="empty-icon">👥</div><div class="empty-text">Нет пользователей</div></div></td></tr>';
    return;
  }
  var html = '';
  users.forEach(function(u,i){
    var pct = u.data_limit>0 ? Math.min(100,Math.round((u.data_used||0)/u.data_limit*100)) : 0;
    var bc = pct>90?'red':pct>70?'yellow':'green';
    html += '<tr>';
    html += '<td><div style="font-weight:700">'+u.username+'</div>'+(u.note?'<div style="font-size:11px;color:var(--muted)">'+u.note+'</div>':'')+'</td>';
    html += '<td><span class="badge '+(u.status==='active'?'badge-green':u.status==='expired'?'badge-red':u.status==='overlimit'?'badge-yellow':'badge-purple')+'">'+u.status+'</span>'; if(u.status==='active' && window._activeIPs && window._activeIPs[u.id]) html += ' <span style="font-size:11px;background:rgba(63,185,80,0.15);color:var(--green);padding:2px 6px;border-radius:4px">'+ window._activeIPs[u.id] +'IP</span>'; html += '</td>';
    html += '<td><div class="mono">'+fmtBytes(u.data_used||0)+' / '+(u.data_limit?fmtBytes(u.data_limit):'∞')+'</div>';
    if(u.data_limit) html += '<div class="progress"><div class="progress-bar '+bc+'" style="width:'+pct+'%"></div></div>';
    html += '</td>';
    html += '<td class="mono">'+fmtDate(u.expire_at)+'</td>';
    html += '<td><div style="display:flex;gap:4px">';
    html += '<button class="btn btn-secondary btn-sm" data-i="'+i+'" data-a="keys">🔑</button>';
    html += '<button class="btn btn-secondary btn-sm" data-i="'+i+'" data-a="stats">📊</button>';
    html += '<button class="btn btn-success btn-sm" data-i="'+i+'" data-a="extend">+⏱</button>';
    html += '<button class="btn btn-secondary btn-sm" data-i="'+i+'" data-a="toggle">'+(u.status==='active'?'⏸':'▶️')+'</button>';
    html += '<button class="btn btn-danger btn-sm" data-i="'+i+'" data-a="del">🗑</button>';
    html += '</div></td></tr>';
  });
  tb.innerHTML = html;
  tb.querySelectorAll('[data-a]').forEach(function(btn){
    btn.addEventListener('click', function(){
      var u = _users[parseInt(this.getAttribute('data-i'))];
      var a = this.getAttribute('data-a');
      if(a==='keys') showKeys(u);
      else if(a==='stats') showUserStats(u);
      else if(a==='extend'){
        document.getElementById('extend-uid').value = u.id;
        document.getElementById('extend-username').textContent = u.username;
        openModal('modal-extend');
      }
      else if(a==='toggle') api('PUT','/users/'+u.id,{status:u.status==='active'?'disabled':'active'}).then(loadUsers);
      else if(a==='del'){
        if(confirm('Удалить '+u.username+'?'))
          api('DELETE','/users/'+u.id).then(function(){ loadUsers(); loadDash(); });
      }
    });
  });
}

document.getElementById('user-search').oninput = function(){
  var q = this.value.toLowerCase();
  renderUsers(_users.filter(function(u){ return u.username.toLowerCase().includes(q); }));
};

document.getElementById('btn-add-user').onclick = function(){ openModal('modal-add-user'); };
document.getElementById('btn-submit-user').onclick = function(){
  var btn = this; btn.disabled = true;
  api('POST','/users',{
    username: document.getElementById('u-username').value.trim(),
    telegram_id: document.getElementById('u-tgid').value.trim()||null,
    expire_days: parseInt(document.getElementById('u-days').value)||30,
    data_limit_mb: parseFloat(document.getElementById('u-limit').value)||0,
    note: document.getElementById('u-note').value.trim(),
    node_ids: ['main']
  }).then(function(){
    closeModal('modal-add-user');
    btn.disabled = false;
    loadUsers(); loadDash();
    toast('✅ Пользователь создан!');
  });
};

// KEYS
function showKeys(u) {
  document.getElementById('keys-username').textContent = u.username;
  document.getElementById('keys-grid').innerHTML = '<div style="color:var(--muted);text-align:center;padding:20px">⏳ Загрузка...</div>';
  openModal('modal-keys');
  api('GET', '/users/' + u.id + '/keys').then(function(data) {
    if (!data || !data.keys) return;
    var html = '';
    if (data.sub_url) {
      html += '<div style="margin-bottom:12px">';
      html += '<div style="font-size:11px;color:var(--muted);margin-bottom:4px">🔗 Ссылка подписки</div>';
      html += '<div style="display:flex;gap:8px;align-items:center">';
      html += '<input class="form-input" style="font-size:11px" readonly data-copy="1" value="' + data.sub_url + '">';
      html += '<button class="btn btn-sm btn-secondary copy-btn">📋</button>';
      html += '</div></div>';
    }
    data.keys.forEach(function(k) {
      var color = k.type === 'vless' ? 'var(--accent)' : 'var(--cyan)';
      html += '<div style="margin-bottom:12px">';
      html += '<div style="font-size:11px;color:var(--muted);margin-bottom:4px">' + k.label + '</div>';
      html += '<div style="display:flex;gap:8px;align-items:center">';
      html += '<input class="form-input" style="font-size:11px;color:' + color + '" readonly data-copy="1" value="' + k.key + '">';
      html += '<button class="btn btn-sm btn-secondary copy-btn">📋</button>';
      html += '</div></div>';
    });
    var grid = document.getElementById('keys-grid');
    grid.innerHTML = html || '<div style="color:var(--muted)">Нет ключей</div>';
    grid.querySelectorAll('.copy-btn').forEach(function(btn) {
      btn.addEventListener('click', function() {
        var inp = this.previousElementSibling;
        var txt = inp ? inp.value : '';
        if (txt) {
          try { navigator.clipboard.writeText(txt); } catch(e) {
            var ta = document.createElement('textarea');
            ta.value = txt; ta.style.position='fixed'; ta.style.opacity='0';
            document.body.appendChild(ta); ta.focus(); ta.select();
            document.execCommand('copy'); document.body.removeChild(ta);
          }
          btn.textContent = '✅';
          setTimeout(function(){ btn.textContent = '📋'; }, 1500);
        }
      });
    });
  });
}
function copyAllKeys() {
  var inputs = document.querySelectorAll('#keys-grid input');
  var vals = Array.from(inputs).map(function(i){return i.value;}).filter(Boolean);
  if(vals.length){ copyText(vals.join('\n')); toast('✅ Все ключи скопированы!'); }
}
// EXTEND
document.getElementById('btn-submit-extend').onclick = function(){
  var uid = document.getElementById('extend-uid').value;
  var days = parseInt(document.getElementById('extend-days').value)||30;
  api('POST','/users/'+uid+'/extend',{days:days}).then(function(){
    closeModal('modal-extend'); loadUsers(); toast('✅ Продлено на '+days+' дней!');
  });
};

// NODES
function loadNodes() {
  api('GET','/nodes').then(function(nodes){
    if(!nodes) return;
    var html = '';
    nodes.forEach(function(n){
      var on = n.status==='online' || n.id==='ru75' || (n.country||'').includes('Russia');
      var ip = n.ip||n.host||'—';
      html += '<div class="node-card">';
      html += '<div class="node-card-header"><div class="node-name">'+n.name+'</div>';
      html += '<span class="badge '+(on?'badge-green':'badge-red')+'">'+(on?'● Online':'● Offline')+'</span></div>';
      html += '<div class="node-info">';
      html += '<div class="node-info-item"><div class="node-info-label">IP</div><div class="node-info-val">'+ip+'</div></div>';
      html += '<div class="node-info-item"><div class="node-info-label">Страна</div><div class="node-info-val">'+n.country+'</div></div>';
      html += '<div class="node-info-item"><div class="node-info-label">ID</div><div class="node-info-val">'+n.id+'</div></div>';
      html += '<div class="node-info-item"><div class="node-info-label">Статус</div><div class="node-info-val" style="color:'+(on?'var(--green)':'var(--red)')+'">'+n.status+'</div></div>';
      html += '</div>';
      html += '<div style="display:flex;gap:6px;margin-top:12px">';
      html += '<button class="btn btn-secondary btn-sm" style="flex:1" onclick="pingNode(\''+n.id+'\')">📡 Ping</button>';
      html += '<button class="btn btn-danger btn-sm" onclick="delNode(\''+n.id+'\')">🗑</button>';
      html += '</div></div>';
    });
    document.getElementById('nodes-grid').innerHTML = html||'<div class="empty"><div class="empty-icon">🖥</div><div class="empty-text">Нет нод</div></div>';
  });
}

function pingNode(id){ toast('📡 Пингуем...'); api('GET','/nodes/'+id+'/ping').then(function(r){ if(r) toast(r.status==='online'?'✅ Онлайн!':'❌ Оффлайн'); loadNodes(); }); }
function delNode(id){ if(!confirm('Удалить ноду?')) return; api('DELETE','/nodes/'+id).then(function(){ loadNodes(); toast('✅ Удалено'); }); }

document.getElementById('btn-add-node').onclick = function(){ openModal('modal-add-node'); };
document.getElementById('btn-submit-node').onclick = function(){
  var btn=this; btn.disabled=true; btn.textContent='⏳...';
  api('POST','/nodes',{
    id:document.getElementById('n-id').value.trim(),
    name:document.getElementById('n-name').value.trim(),
    host:document.getElementById('n-ip').value.trim(),
    country:document.getElementById('n-country').value.trim()||'--',
    ssh_port:parseInt(document.getElementById('n-ssh-port').value)||22,
    ssh_username:document.getElementById('n-ssh-user').value.trim(),
    ssh_password:document.getElementById('n-ssh-pass').value,
    auto_install:document.getElementById('n-auto').checked
  }).then(function(){ closeModal('modal-add-node'); btn.disabled=false; btn.textContent='🚀 Добавить'; loadNodes(); toast('✅ Нода добавлена!'); });
};

// BRIDGES
function loadBridges() {
  api('GET','/bridges').then(function(bridges){
    var tb = document.getElementById('bridges-tb');
    if(!bridges||!bridges.length){
      tb.innerHTML = '<tr><td colspan="6"><div class="empty"><div class="empty-icon">🌉</div><div class="empty-text">Нет мостов</div></div></td></tr>';
      return;
    }
    var html = '';
    bridges.forEach(function(b){
      html += '<tr><td class="mono">'+b.node_id+'</td><td class="mono">'+b.ru_ip+'</td><td class="mono">'+b.foreign_ip+'</td>';
      html += '<td><span class="badge '+(b.active?'badge-green':'badge-red')+'">'+(b.active?'Активен':'Откл')+'</span></td>';
      html += '<td style="font-size:12px;color:var(--muted)">'+new Date(b.created_at*1000).toLocaleDateString('ru')+'</td>';
      html += '<td><button class="btn btn-danger btn-sm" onclick="delBridge('+b.id+')">🗑</button></td></tr>';
    });
    tb.innerHTML = html;
  });
}

function delBridge(id){ if(!confirm('Удалить мост?')) return; api('DELETE','/bridges/'+id).then(function(){ loadBridges(); toast('✅ Удалено'); }); }

document.getElementById('btn-add-bridge').onclick = function(){
  // Заполняем селекты нодами
  api('GET','/nodes').then(function(nodes){
    var ruSel = document.getElementById('b-ru-node');
    var forSel = document.getElementById('b-foreign-node');
    ruSel.innerHTML = '';
    forSel.innerHTML = '';
    nodes.forEach(function(n){
      var opt1 = '<option value="'+n.id+'" data-host="'+n.host+'" data-ssh-user="'+(n.ssh_user||'root')+'" data-ssh-pass="'+(n.ssh_password||'')+'" data-ssh-port="'+(n.port||22)+'">'+n.name+' ('+n.host+')</option>';
      ruSel.innerHTML += opt1;
      forSel.innerHTML += opt1;
    });
  });
  openModal('modal-add-bridge');
};
document.getElementById('btn-submit-bridge').onclick = function(){
  var btn=this; btn.disabled=true;
  api('POST','/bridges',{
    node_id:document.getElementById('b-ru-node').value,
    ru_ip:document.getElementById('b-ru-node').selectedOptions[0].dataset.host,
    foreign_ip:document.getElementById('b-foreign-node').selectedOptions[0].dataset.host,
    ssh_port:parseInt(document.getElementById('b-ru-node').selectedOptions[0].dataset.sshPort)||22,
    ssh_user:document.getElementById('b-ru-node').selectedOptions[0].dataset.sshUser||'root',
    ssh_password:document.getElementById('b-ru-node').selectedOptions[0].dataset.sshPass||'',
    foreign_ssh_port:parseInt(document.getElementById('b-foreign-node').selectedOptions[0].dataset.sshPort)||22,
    foreign_ssh_user:document.getElementById('b-foreign-node').selectedOptions[0].dataset.sshUser||'root',
    foreign_ssh_password:document.getElementById('b-foreign-node').selectedOptions[0].dataset.sshPass||''
  }).then(function(){ closeModal('modal-add-bridge'); btn.disabled=false; loadBridges(); toast('✅ Мост создан!'); });
};

// HOSTS
function loadHosts() {
  api('GET','/hosts').then(function(hosts){
    var tb = document.getElementById('hosts-tb');
    if(!hosts||!hosts.length){
      tb.innerHTML = '<tr><td colspan="7"><div class="empty"><div class="empty-icon">🌐</div><div class="empty-text">Нет хостов</div></div></td></tr>';
      return;
    }
    var html = '';
    hosts.forEach(function(h){
      html += '<tr>';
      html += '<td><span class="host-tag">'+h.inbound_tag+'</span></td>';
      html += '<td><b>'+h.remark+'</b></td>';
      html += '<td class="mono">'+h.address+'</td>';
      html += '<td class="mono">'+h.port+'</td>';
      html += '<td class="mono">'+(h.sni||'—')+'</td>';
      html += '<td><span class="badge '+(h.active?'badge-green':'badge-red')+'">'+(h.active?'Активен':'Откл')+'</span></td>';
      html += '<td><div style="display:flex;gap:6px">';
      html += '<button class="btn btn-secondary btn-sm" onclick="editHost('+h.id+',this)">✏️</button>';
      html += '<button class="btn btn-danger btn-sm" onclick="delHost('+h.id+')">🗑</button>';
      html += '</div></td></tr>';
    });
    tb.innerHTML = html;
    // Сохраняем данные хостов для редактирования
    document.getElementById('hosts-tb')._hosts = hosts;
  });
}

function editHost(id, btn){
  var hosts = document.getElementById('hosts-tb')._hosts || [];
  var h = hosts.find(function(x){ return x.id===id; });
  if(!h) return;
  document.getElementById('edit-host-id').value = h.id;
  document.getElementById('edit-host-remark').value = h.remark;
  document.getElementById('edit-host-address').value = h.address;
  document.getElementById('edit-host-port').value = h.port;
  document.getElementById('edit-host-sni').value = h.sni||'';
  openModal('modal-host-edit');
}

function delHost(id){ if(!confirm('Удалить хост?')) return; api('DELETE','/hosts/'+id).then(function(){ loadHosts(); toast('✅ Удалено'); }); }

document.getElementById('btn-save-host').onclick = function(){
  var id = document.getElementById('edit-host-id').value;
  api('PUT','/hosts/'+id,{
    remark:document.getElementById('edit-host-remark').value.trim(),
    address:document.getElementById('edit-host-address').value.trim(),
    port:parseInt(document.getElementById('edit-host-port').value),
    sni:document.getElementById('edit-host-sni').value.trim()
  }).then(function(){ closeModal('modal-host-edit'); loadHosts(); toast('✅ Хост обновлён!'); });
};

document.getElementById('btn-add-host').onclick = function(){ openModal('modal-host-add'); };
document.getElementById('btn-submit-host-add').onclick = function(){
  api('POST','/hosts',{
    inbound_tag:document.getElementById('add-host-tag').value,
    remark:document.getElementById('add-host-remark').value.trim(),
    address:document.getElementById('add-host-address').value.trim(),
    port:parseInt(document.getElementById('add-host-port').value)||443,
    sni:document.getElementById('add-host-sni').value.trim()
  }).then(function(){ closeModal('modal-host-add'); loadHosts(); toast('✅ Хост добавлен!'); });
};

document.getElementById('btn-regen-all').onclick = function(){
  var btn=this; btn.textContent='⏳...'; btn.disabled=true;
  api('POST','/hosts/regen').then(function(){
    btn.textContent='🔄 Перегенерировать ключи'; btn.disabled=false; toast('✅ Ключи обновлены!');
  });
};

// TRAFFIC
function loadTraffic() {
  api('GET','/traffic/stats').then(function(data){
    if(!data) return;
    document.getElementById('tr-total').textContent = fmtBytes(data.total_traffic_bytes||0);
    document.getElementById('tr-expired').textContent = data.expired_users||0;
    document.getElementById('tr-overlimit').textContent = data.overlimit_users||0;
    var ng = document.getElementById('node-traffic-grid');
    if(data.nodes&&data.nodes.length){
      var nh = '';
      data.nodes.forEach(function(n){
        var total = (n.bytes_up||0)+(n.bytes_down||0);
        nh += '<div class="traffic-node-card">';
        nh += '<div class="tncl">📡 '+n.name+'</div>';
        nh += '<div class="tncv">'+fmtBytes(total)+'</div>';
        nh += '<div class="tncs"><span class="up">↑ '+fmtBytes(n.bytes_up||0)+'</span><span class="dn">↓ '+fmtBytes(n.bytes_down||0)+'</span></div>';
        nh += '</div>';
      });
      ng.innerHTML = nh;
    }
    var tb = document.getElementById('traffic-tb');
    if(data.users&&data.users.length){
      var html = '';
      data.users.forEach(function(u){
        var pct = u.data_limit_mb>0 ? Math.min(100,Math.round(u.data_used_gb/u.data_limit_mb*100)) : 0;
        var bc = pct>90?'red':pct>70?'yellow':'green';
        html += '<tr>';
        html += '<td><b>'+u.username+'</b></td>';
        html += '<td class="mono">'+u.data_used_mb+' MB</td>';
        html += '<td class="mono">'+(u.data_limit?Math.round(u.data_limit/1024/1024)+' MB':'∞')+'</td>';
        html += '<td style="min-width:120px">'+(u.data_limit_mb?'<div class="progress"><div class="progress-bar '+bc+'" style="width:'+pct+'%"></div></div><div style="font-size:11px;color:var(--muted)">'+pct+'%</div>':'—')+'</td>';
        html += '<td><span class="badge '+(u.status==='active'?'badge-green':u.status==='expired'?'badge-red':'badge-yellow')+'">'+u.status+'</span></td>';
        html += '<td class="mono">'+fmtDate(u.expire_at)+'</td>';
        html += '</tr>';
      });
      tb.innerHTML = html;
    }
  });
}

// ADMINS
function loadAdmins() {
  // Показываем главного admin
  var container = document.getElementById('admins-tb') ? document.getElementById('admins-tb').closest('.table-card') : null;
  if(container && !container._mainShown){
    container._mainShown = true;
    var mainHtml = '<div style="background:var(--bg3);border-radius:8px;padding:12px 16px;margin-bottom:12px;display:flex;align-items:center;justify-content:space-between">';
    mainHtml += '<div><b>admin</b> <span class="badge badge-purple">Главный</span></div>';
    mainHtml += '<button class="btn btn-secondary btn-sm" onclick="changeMainPass()">🔐 Сменить пароль</button>';
    mainHtml += '</div>';
    container.insertAdjacentHTML('afterbegin', mainHtml);
  }
  api('GET','/subadmins').then(function(admins){
    var tb = document.getElementById('admins-tb');
    if(!admins||!admins.length){
      tb.innerHTML = '<tr><td colspan="4"><div class="empty"><div class="empty-icon">👮</div><div class="empty-text">Нет субадминов</div></div></td></tr>';
      return;
    }
    var html = '';
    admins.forEach(function(a){
      var perms = [];
      if(a.can_add_users) perms.push('add');
      if(a.can_delete_users) perms.push('del');
      if(a.can_view_keys) perms.push('keys');
      if(a.can_manage_nodes) perms.push('nodes');
      html += '<tr><td><b>'+a.username+'</b></td>';
      html += '<td>'+perms.map(function(p){ return '<span class="badge badge-blue">'+p+'</span>'; }).join(' ')+'</td>';
      html += '<td style="font-size:12px;color:var(--muted)">'+new Date(a.created_at*1000).toLocaleDateString('ru')+'</td>';
      html += '<td><button class="btn btn-danger btn-sm" onclick="delAdmin('+a.id+')">🗑</button></td></tr>';
    });
    tb.innerHTML = html;
  });
}

function delAdmin(id){ if(!confirm('Удалить?')) return; api('DELETE','/subadmins/'+id).then(function(){ loadAdmins(); toast('✅ Удалён'); }); }

document.getElementById('btn-add-admin').onclick = function(){ openModal('modal-add-admin'); };
document.getElementById('btn-submit-admin').onclick = function(){
  api('POST','/subadmins',{
    username:document.getElementById('a-username').value.trim(),
    password:document.getElementById('a-password').value,
    can_add_users:document.getElementById('a-add').checked?1:0,
    can_delete_users:document.getElementById('a-del').checked?1:0,
    can_toggle_users:document.getElementById('a-toggle').checked?1:0,
    can_view_keys:document.getElementById('a-keys').checked?1:0,
    can_manage_nodes:document.getElementById('a-nodes').checked?1:0,
    can_manage_bridges:document.getElementById('a-bridges').checked?1:0
  }).then(function(){ closeModal('modal-add-admin'); loadAdmins(); toast('✅ Создан!'); });
};

// BOTS
function loadBots() {
  api('GET','/bots').then(function(bots){
    var tb = document.getElementById('bots-tb');
    if(!bots||!bots.length){
      tb.innerHTML = '<tr><td colspan="3"><div class="empty"><div class="empty-icon">🤖</div><div class="empty-text">Нет ботов</div></div></td></tr>';
      return;
    }
    var html = '';
    bots.forEach(function(b){
      html += '<tr><td><b>'+b.name+'</b></td>';
      html += '<td style="font-size:12px;color:var(--muted)">'+new Date(b.created_at*1000).toLocaleDateString('ru')+'</td>';
      html += '<td><button class="btn btn-danger btn-sm" onclick="delBot('+b.id+')">🗑</button></td></tr>';
    });
    tb.innerHTML = html;
  });
}

function delBot(id){ if(!confirm('Удалить?')) return; api('DELETE','/bots/'+id).then(function(){ loadBots(); toast('✅ Удалён'); }); }

document.getElementById('btn-add-bot').onclick = function(){ openModal('modal-add-bot'); };
document.getElementById('btn-submit-bot').onclick = function(){
  api('POST','/bots',{name:document.getElementById('bot-name').value.trim()}).then(function(r){
    closeModal('modal-add-bot');
    if(r&&r.token){ document.getElementById('bot-token-val').textContent=r.token; openModal('modal-bot-token'); }
    loadBots();
  });
};

// SETTINGS
function loadSettingsPage() {
  api('GET','/settings').then(function(s){
    if(!s) return;
    document.getElementById('s-tg-token').value = s.tg_bot_token||'';
    document.getElementById('s-tg-admin').value = s.tg_admin_id||'';
    document.getElementById('s-domain').value = s.panel_domain||'';
    document.getElementById('s-sub-domain').value = s.sub_domain||'';
    document.getElementById('s-tg-nodes').checked = s.tg_notify_node!=='0';
    document.getElementById('s-tg-users').checked = s.tg_notify_user!=='0';
    if(s.panel_domain) localStorage.setItem('vpn_domain', s.panel_domain);
  });
  loadSysStats();
}

document.getElementById('btn-save-settings').onclick = function(){
  var domain = document.getElementById('s-domain').value.trim();
  api('PUT','/settings',{
    tg_bot_token:document.getElementById('s-tg-token').value.trim(),
    tg_admin_id:document.getElementById('s-tg-admin').value.trim(),
    panel_domain:domain,
    sub_domain:document.getElementById('s-sub-domain').value.trim(),
    tg_notify_node:document.getElementById('s-tg-nodes').checked?'1':'0',
    tg_notify_user:document.getElementById('s-tg-users').checked?'1':'0',
  }).then(function(){
    if(domain) localStorage.setItem('vpn_domain', domain);
    toast('✅ Настройки сохранены!');
  });
};

document.getElementById('btn-test-tg').onclick = function(){
  var btn=this; btn.textContent='⏳...'; btn.disabled=true;
  api('POST','/system/notify-test').then(function(r){
    btn.disabled=false;
    btn.textContent = r&&r.ok?'✅ Отправлено!':'❌ Ошибка';
    setTimeout(function(){ btn.textContent='📤 Тест уведомления'; },3000);
  });
};




function loadInbounds() {
  api('GET','/inbounds').then(function(inbounds){
    var g = document.getElementById('inbounds-grid');
    if(!inbounds||!g) return;
    g._data = inbounds;
    var html = '';
    inbounds.forEach(function(ib){
      var color = ib.type==='vless' ? 'var(--accent)' : 'var(--cyan)';
      var clients = (ib.raw.users||[]).length;
      var tls = ib.raw.tls||{};
      var reality = tls.reality||{};
      var sni = tls.server_name||(reality.handshake&&reality.handshake.server)||'—';
      html += '<div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:20px">';
      html += '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">';
      html += '<div><div style="font-weight:700;font-size:15px">'+ib.tag+'</div>';
      html += '<div style="font-size:12px;color:var(--muted)">'+ib.type.toUpperCase()+'</div></div>';
      html += '<span class="badge badge-green">Active</span></div>';
      html += '<div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:16px">';
      html += '<div style="background:var(--bg3);border-radius:8px;padding:12px"><div style="font-size:11px;color:var(--muted)">ПОРТ</div><div style="font-size:20px;font-weight:700;color:'+color+'">'+ib.port+'</div></div>';
      html += '<div style="background:var(--bg3);border-radius:8px;padding:12px"><div style="font-size:11px;color:var(--muted)">КЛИЕНТОВ</div><div style="font-size:20px;font-weight:700">'+clients+'</div></div>';
      html += '</div>';
      html += '<div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;font-size:12px;margin-bottom:16px">';
      html += '<div style="color:var(--muted)">SNI:</div><div class="mono">'+sni+'</div>';
      if(reality.enabled) html += '<div style="color:var(--muted)">Reality:</div><div><span class="badge badge-purple">ON</span></div>';
      html += '</div>';
      html += '<div style="display:flex;gap:8px">';
      html += '<button class="btn btn-secondary btn-sm" style="flex:1" data-tag="'+ib.tag+'" data-action="edit-inbound">✏️ Редактировать</button>';
      html += '<button class="btn btn-danger btn-sm" data-tag="'+ib.tag+'" data-action="del-inbound">🗑</button>';
      html += '</div></div>';
    });
    g.innerHTML = html || '<div class="empty"><div class="empty-icon">⚡</div><div class="empty-text">Нет inbounds</div></div>';
    if(!g._delegated){
      g._delegated = true;
      g.addEventListener('click', function(e){
        var btn = e.target.closest('[data-action]');
        if(!btn) return;
        var tag = btn.getAttribute('data-tag');
        var action = btn.getAttribute('data-action');
        var ib = (g._data||[]).find(function(x){return x.tag===tag;});
        if(action==='del-inbound'){
          if(!confirm('Удалить '+tag+'?')) return;
          api('DELETE','/inbounds/'+tag).then(function(r){ if(r&&r.ok){toast('✅ Удалено!');setTimeout(loadInbounds,2000);} });
        } else if(action==='edit-inbound' && ib){
          var tls=ib.raw.tls||{}, reality=tls.reality||{};
          document.getElementById('edit-ib-tag').value=tag;
          document.getElementById('edit-ib-port').value=ib.port;
          document.getElementById('edit-ib-listen').value=ib.listen||'::';
          document.getElementById('edit-ib-sni').value=tls.server_name||'';
          if(reality.handshake){document.getElementById('edit-ib-hs-server').value=reality.handshake.server||'';document.getElementById('edit-ib-hs-port').value=reality.handshake.server_port||443;}
          if(reality.short_id) document.getElementById('edit-ib-shortid').value=(reality.short_id||[''])[0];
          openModal('modal-inbound-edit');
        }
      });
    }
  });
}

function loadChart(type, days) {
  if(typeof Chart === 'undefined'){ setTimeout(function(){ loadChart(type, days); }, 500); return; }
  type = type || 'traffic';
  days = days || 7;
  // Подсветка кнопок
  ['chart-7d','chart-30d','chart-90d','chart-users'].forEach(function(id){
    var el=document.getElementById(id);
    if(el) el.style.opacity='0.5';
  });
  if(type==='users'){ var btn=document.getElementById('chart-users'); if(btn) btn.style.opacity='1'; }
  else if(days===7){ var btn=document.getElementById('chart-7d'); if(btn) btn.style.opacity='1'; }
  else if(days===30){ var btn=document.getElementById('chart-30d'); if(btn) btn.style.opacity='1'; }
  else if(days===90){ var btn=document.getElementById('chart-90d'); if(btn) btn.style.opacity='1'; }

  api('GET','/traffic/daily?days='+days).then(function(data){
    if(!data) return;
    var labels = data.map(function(d){ return d.label; });
    var values, label, color;
    if(type==='users'){ values=data.map(function(d){return d.active_users;}); label='Активных'; color='rgba(88,166,255,0.8)'; }
    else { values=data.map(function(d){return d.traffic_gb;}); label='Трафик GB'; color='rgba(63,185,80,0.8)'; }
    var canvas = document.getElementById('dash-chart');
    if(!canvas) return;
    if(window._chart){ window._chart.destroy(); window._chart=null; }
    window._chart = new Chart(canvas.getContext('2d'), {
      type:'bar',
      data:{labels:labels, datasets:[{label:label, data:values, backgroundColor:color, borderRadius:6}]},
      options:{responsive:true, maintainAspectRatio:false,
        plugins:{legend:{labels:{color:'#8b949e'}}},
        scales:{x:{ticks:{color:'#8b949e'},grid:{color:'rgba(255,255,255,0.05)'}},
                y:{ticks:{color:'#8b949e'},grid:{color:'rgba(255,255,255,0.05)'},beginAtZero:true}}}
    });
  });
}

function filterUsers() {
  var status = document.getElementById('filter-status');
  var sort = document.getElementById('filter-sort');
  var q = document.getElementById('user-search');
  var sv=status?status.value:'', so=sort?sort.value:'', qv=q?q.value.toLowerCase():'';
  var filtered = _users.filter(function(u){
    if(qv && !u.username.toLowerCase().includes(qv)) return false;
    if(sv && u.status!==sv) return false;
    return true;
  });
  if(so==='traffic') filtered.sort(function(a,b){return (b.data_used||0)-(a.data_used||0);});
  else if(so==='expire') filtered.sort(function(a,b){return (a.expire_at||0)-(b.expire_at||0);});
  else if(so==='name') filtered.sort(function(a,b){return a.username.localeCompare(b.username);});
  renderUsers(filtered);
}


window.changeMainPass = function(){
  var pass = prompt('Введите новый пароль для admin:');
  if(!pass||pass.length<4){ if(pass!==null) toast('❌ Минимум 4 символа!'); return; }
  api('POST','/change-password',{old_password:'',new_password:pass,force:true}).then(function(r){
    if(r&&r.ok) toast('✅ Пароль изменён!');
    else toast('❌ Ошибка');
  });
};

document.getElementById('btn-save-inbound').onclick = function(){
  var tag = document.getElementById('edit-ib-tag').value;
  api('PUT','/inbounds/'+tag+'/full', {
    port: parseInt(document.getElementById('edit-ib-port').value),
    listen: document.getElementById('edit-ib-listen').value,
    sni: document.getElementById('edit-ib-sni').value,
    hs_server: document.getElementById('edit-ib-hs-server').value,
    hs_port: parseInt(document.getElementById('edit-ib-hs-port').value),
    short_id: document.getElementById('edit-ib-shortid').value,
  }).then(function(r){
    if(r&&r.ok){closeModal('modal-inbound-edit');toast('✅ Сохранено!');setTimeout(loadInbounds,3000);}
  });
};

document.getElementById('btn-create-inbound').onclick = function(){
  var btn=this; btn.disabled=true;
  api('POST','/inbounds/add', {
    type: document.getElementById('add-ib-type').value,
    tag: document.getElementById('add-ib-tag').value,
    port: parseInt(document.getElementById('add-ib-port').value),
    sni: document.getElementById('add-ib-sni').value,
  }).then(function(r){
    btn.disabled=false;
    if(r&&r.ok){closeModal('modal-inbound-add');toast('✅ Создан!');setTimeout(loadInbounds,3000);}
  });
};

// Делегирование для admins-tb
var adminsTb = document.getElementById('admins-tb');
if(adminsTb && !adminsTb._delegated){
  adminsTb._delegated = true;
  adminsTb.addEventListener('click', function(e){
    var btn = e.target.closest('[data-action="change-pass-admin"]');
    if(!btn) return;
    document.getElementById('cp-admin-id').value = btn.getAttribute('data-id');
    document.getElementById('cp-username').textContent = btn.getAttribute('data-name');
    document.getElementById('cp-new-pass').value = '';
    openModal('modal-change-pass');
  });
}

document.getElementById('btn-save-pass').onclick = function(){
  var id = document.getElementById('cp-admin-id').value;
  var pass = document.getElementById('cp-new-pass').value;
  if(!pass||pass.length<4){ toast('❌ Минимум 4 символа!'); return; }
  api('POST','/subadmins/'+id+'/change-password',{password:pass}).then(function(r){
    if(r&&r.ok){ closeModal('modal-change-pass'); toast('✅ Пароль изменён!'); }
  });
};


function exportUsers(){
  fetch('/api/users/export',{headers:{'Authorization':'Bearer '+TOKEN}})
    .then(function(r){return r.blob();})
    .then(function(b){
      var a=document.createElement('a');
      a.href=URL.createObjectURL(b);
      a.download='users.csv';
      a.click();
    });
}

function importUsers(){
  var inp=document.createElement('input');
  inp.type='file'; inp.accept='.csv';
  inp.onchange=function(){
    var fd=new FormData();
    fd.append('file',inp.files[0]);
    fetch('/api/users/import',{method:'POST',headers:{'Authorization':'Bearer '+TOKEN},body:fd})
      .then(function(r){return r.json();})
      .then(function(r){loadUsers();toast('✅ Импортировано: '+r.imported);});
  };
  inp.click();
}

function createTemplate(){
  var name=document.getElementById('t-name').value.trim();
  var days=parseInt(document.getElementById('t-days').value)||30;
  var limit=parseFloat(document.getElementById('t-limit').value)||0;
  if(!name){toast('❌ Введите название!');return;}
  api('POST','/templates',{name:name,expire_days:days,data_limit_mb:limit}).then(function(){
    loadTemplates();
    document.getElementById('t-name').value='';
    toast('✅ Шаблон создан!');
  });
}

function deleteTemplate(id){
  if(!confirm('Удалить шаблон?')) return;
  api('DELETE','/templates/'+id).then(function(){ loadTemplates(); toast('✅ Удалён'); });
}

function useTemplate(id){
  var t=_templates&&_templates.find(function(x){return x.id===id;});
  if(!t) return;
  document.getElementById('u-days').value=t.expire_days;
  document.getElementById('u-limit').value=t.data_limit_mb;
  document.getElementById('u-note').value=t.note||'';
  closeModal('modal-templates');
  openModal('modal-add-user');
  toast('✅ Шаблон применён!');
}

function loadAudit(){
  api('GET','/logs?limit=100').then(function(rows){
    if(!rows) return;
    var html='';
    if(!rows.length) html='<div style="color:var(--muted);text-align:center;padding:20px">Лог пуст</div>';
    rows.forEach(function(r){
      var d=new Date(r.created_at*1000);
      html+='<div style="padding:8px 0;border-bottom:1px solid var(--border);font-size:13px">'+
        d.toLocaleDateString('ru')+' '+d.toLocaleTimeString('ru')+
        ' <b style="color:var(--accent)">'+r.admin+'</b> '+r.action+'</div>';
    });
    document.getElementById('audit-list').innerHTML=html;
    openModal('modal-audit');
  });
}



function importUsers(){
  var inp=document.createElement('input');
  inp.type='file'; inp.accept='.csv';
  inp.onchange=function(){
    var fd=new FormData();
    fd.append('file',inp.files[0]);
    fetch('/api/users/import',{method:'POST',headers:{'Authorization':'Bearer '+TOKEN},body:fd})
      .then(function(r){return r.json();})
      .then(function(r){loadUsers();toast('✅ Импортировано: '+r.imported);});
  };
  inp.click();
}

function createTemplate(){
  var name=document.getElementById('t-name').value.trim();
  var days=parseInt(document.getElementById('t-days').value)||30;
  var limit=parseFloat(document.getElementById('t-limit').value)||0;
  if(!name){toast('❌ Введите название!');return;}
  api('POST','/templates',{name:name,expire_days:days,data_limit_mb:limit}).then(function(){
    loadTemplates();
    document.getElementById('t-name').value='';
    toast('✅ Шаблон создан!');
  });
}

function deleteTemplate(id){
  if(!confirm('Удалить шаблон?')) return;
  api('DELETE','/templates/'+id).then(function(){ loadTemplates(); toast('✅ Удалён'); });
}

function useTemplate(id){
  var t=_templates&&_templates.find(function(x){return x.id===id;});
  if(!t) return;
  document.getElementById('u-days').value=t.expire_days;
  document.getElementById('u-limit').value=t.data_limit_mb;
  document.getElementById('u-note').value=t.note||'';
  closeModal('modal-templates');
  openModal('modal-add-user');
  toast('✅ Шаблон применён!');
}

function loadAudit(){
  api('GET','/logs?limit=100').then(function(rows){
    if(!rows) return;
    var html='';
    if(!rows.length) html='<div style="color:var(--muted);text-align:center;padding:20px">Лог пуст</div>';
    rows.forEach(function(r){
      var d=new Date(r.created_at*1000);
      html+='<div style="padding:8px 0;border-bottom:1px solid var(--border);font-size:13px">'+
        d.toLocaleDateString('ru')+' '+d.toLocaleTimeString('ru')+
        ' <b style="color:var(--accent)">'+r.admin+'</b> '+r.action+'</div>';
    });
    document.getElementById('audit-list').innerHTML=html;
    openModal('modal-audit');
  });
}


function loadSysStats(){
  api('GET','/system/stats').then(function(s){
    if(!s) return;
    var R=32, C=2*Math.PI*R;
    function setEl(id,val){var e=document.getElementById(id);if(e)e.textContent=val;}
    function setCircle(id,pct,color){
      var e=document.getElementById(id);
      if(!e) return;
      e.style.strokeDashoffset=C-(pct/100)*C;
      e.style.stroke=color||'#3fb950';
    }
    function getColor(pct){
      if(pct>=80) return '#f85149';
      if(pct>=50) return '#f0a500';
      return '#3fb950';
    }
    setEl('sys-cpu', s.cpu_percent+'%');
    setCircle('cpu-circle', s.cpu_percent, getColor(s.cpu_percent));
    setEl('sys-ram', s.ram_percent+'%');
    setCircle('ram-circle', s.ram_percent, getColor(s.ram_percent));
    setEl('sys-ram-detail', s.ram_used_gb+' / '+s.ram_total_gb+' GB');
    setEl('sys-disk', s.disk_percent+'%');
    setCircle('disk-circle', s.disk_percent, getColor(s.disk_percent));
    setEl('sys-disk-detail', s.disk_used_gb+' / '+s.disk_total_gb+' GB');
    setEl('sys-recv', s.net_recv_gb+' GB');
    setEl('sys-sent', s.net_sent_gb+' GB');
    if(s.uptime_seconds){
      var u=s.uptime_seconds;
      var d=Math.floor(u/86400),h=Math.floor((u%86400)/3600),m=Math.floor((u%3600)/60);
      var ut=d+'д '+h+'ч '+m+'м';
      setEl('sys-uptime',ut);
      setEl('sys-uptime2',ut);
    }
  });
}


function _resetChartBtns(){
  ['chart-7d','chart-30d','chart-90d','chart-users','chart-proto','chart-nodes','chart-hourly'].forEach(function(id){
    var el=document.getElementById(id); if(el) el.style.opacity='0.5';
  });
}
function _drawChart(labels, datasets, type){
  var canvas = document.getElementById('dash-chart');
  if(!canvas) return;
  if(window._chart){ window._chart.destroy(); window._chart=null; }
  window._chart = new Chart(canvas.getContext('2d'), {
    type: type||'bar',
    data:{labels:labels, datasets:datasets},
    options:{responsive:true, maintainAspectRatio:false,
      plugins:{legend:{labels:{color:'#8b949e'}}},
      scales:{x:{ticks:{color:'#8b949e'},grid:{color:'rgba(255,255,255,0.05)'}},
              y:{ticks:{color:'#8b949e'},grid:{color:'rgba(255,255,255,0.05)'},beginAtZero:true}}}
  });
}

function loadProtoChart(){
  if(typeof Chart==='undefined'){setTimeout(loadProtoChart,500);return;}
  _resetChartBtns();
  var btn=document.getElementById('chart-proto'); if(btn) btn.style.opacity='1';
  api('GET','/traffic/by-protocol?days=7').then(function(data){
    if(!data||!data.length){
      _drawChart(['Нет данных'],
        [{label:'Нет данных',data:[0],backgroundColor:'rgba(88,166,255,0.5)'}]);
      return;
    }
    var labels = data.map(function(d){return d.protocol;});
    var up = data.map(function(d){return d.upload_gb;});
    var down = data.map(function(d){return d.download_gb;});
    _drawChart(labels,[
      {label:'↑ Upload GB',data:up,backgroundColor:'rgba(88,166,255,0.8)',borderRadius:6},
      {label:'↓ Download GB',data:down,backgroundColor:'rgba(63,185,80,0.8)',borderRadius:6}
    ]);
  });
}

function loadNodeChart(){
  if(typeof Chart==='undefined'){setTimeout(loadNodeChart,500);return;}
  _resetChartBtns();
  var btn=document.getElementById('chart-nodes'); if(btn) btn.style.opacity='1';
  api('GET','/traffic/by-node?days=7').then(function(data){
    if(!data||!data.length){
      _drawChart(['Нет данных'],
        [{label:'Нет данных',data:[0],backgroundColor:'rgba(240,165,0,0.5)'}]);
      return;
    }
    var labels = data.map(function(d){return d.node;});
    var up = data.map(function(d){return d.upload_gb;});
    var down = data.map(function(d){return d.download_gb;});
    _drawChart(labels,[
      {label:'↑ Upload GB',data:up,backgroundColor:'rgba(240,165,0,0.8)',borderRadius:6},
      {label:'↓ Download GB',data:down,backgroundColor:'rgba(63,185,80,0.8)',borderRadius:6}
    ]);
  });
}

function loadHourlyChart(){
  if(typeof Chart==='undefined'){setTimeout(loadHourlyChart,500);return;}
  _resetChartBtns();
  var btn=document.getElementById('chart-hourly'); if(btn) btn.style.opacity='1';
  api('GET','/traffic/hourly?hours=24').then(function(data){
    if(!data||!data.length){
      _drawChart(['Нет данных'],
        [{label:'Нет данных',data:[0],backgroundColor:'rgba(88,166,255,0.5)'}]);
      return;
    }
    var labels = data.map(function(d){return d.label;});
    var vless = data.map(function(d){return (d.vless_up+d.vless_down);});
    var hy2 = data.map(function(d){return (d.hy2_up+d.hy2_down);});
    _drawChart(labels,[
      {label:'VLESS MB',data:vless,backgroundColor:'rgba(88,166,255,0.8)',borderRadius:4},
      {label:'Hysteria2 MB',data:hy2,backgroundColor:'rgba(63,185,80,0.8)',borderRadius:4}
    ]);
  });
}


function loadBandwidth(){
  api('GET','/bandwidth').then(function(d){
    if(!d) return;
    function setEl(id,val){ var e=document.getElementById(id); if(e) e.textContent=val; }
    function setVs(id,obj){
      var e=document.getElementById(id);
      if(e&&obj){ e.textContent=obj.text; e.style.color=obj.color; }
    }
    setEl('bw-today', d.today);
    setEl('bw-7d', d.last_7d);
    setEl('bw-30d', d.last_30d);
    setEl('bw-month', d.cal_month);
    setEl('bw-year', d.year);
    setVs('bw-today-vs', d.today_vs);
    setVs('bw-7d-vs', d.last_7d_vs);
    setVs('bw-30d-vs', d.last_30d_vs);
  });
}


function loadDashStats(){
  function setEl(id,val){ var e=document.getElementById(id); if(e) e.textContent=val; }
  // Протоколы и ноды
  api('GET','/traffic/by-protocol?days=7').then(function(data){
    if(!data) return;
    data.forEach(function(d){
      if(d.protocol==='vless') setEl('stat-vless', round2(d.upload_gb+d.download_gb)+' GB');
      if(d.protocol==='hysteria2') setEl('stat-hy2', round2(d.upload_gb+d.download_gb)+' GB');
    });
    if(!data.length){ setEl('stat-vless','0 GB'); setEl('stat-hy2','0 GB'); }
  });
  api('GET','/traffic/by-node?days=7').then(function(data){
    if(!data) return;
    data.forEach(function(d){
      if(d.node==='main') setEl('stat-main', round2(d.upload_gb+d.download_gb)+' GB');
      if(d.node==='ru75') setEl('stat-ru75', round2(d.upload_gb+d.download_gb)+' GB');
    });
    if(!data.length){ setEl('stat-main','0 GB'); setEl('stat-ru75','0 GB'); }
  });
  // Новых за 7 дней
  api('GET','/traffic/daily?days=7').then(function(data){
    if(!data) return;
    var newU = data.reduce(function(s,d){return s+(d.new_users||0);},0);
    var activeToday = data.length ? (data[data.length-1].active_users||0) : 0;
    setEl('stat-new-users', newU);
    setEl('stat-active-today', activeToday);
  });
  // DL/UL из system stats
  api('GET','/system/stats').then(function(s){
    if(!s) return;
    setEl('stat-dl', s.net_recv_gb+' GB');
    setEl('stat-ul', s.net_sent_gb+' GB');
  });
}

function round2(n){ return Math.round(n*100)/100; }


// Автообновление дашборда каждые 30 сек
setInterval(function(){
  var page = document.querySelector('.page.active');
  if(page && page.id === 'page-dash'){
    loadSysStats();
    loadBandwidth();
    loadDashStats();
  }
}, 30000);

window.loadSysStats = loadSysStats;
window.loadBandwidth = loadBandwidth;
window.loadDashStats = loadDashStats;

function showUserStats(u){
  document.getElementById('ustat-name').textContent = u.username;
  document.getElementById('ustat-traffic').textContent = fmtBytes(u.data_used||0);
  document.getElementById('ustat-limit').textContent = u.data_limit ? fmtBytes(u.data_limit) : '∞';
  document.getElementById('ustat-expire').textContent = fmtDate(u.expire_at);
  document.getElementById('ustat-status').textContent = u.status;
  // Загружаем статистику по протоколам из connection_logs
  api('GET','/users/'+u.id+'/stats').then(function(s){
    if(!s){ 
      document.getElementById('ustat-proto').innerHTML = '<div style="color:var(--muted);text-align:center;padding:20px">Нет данных о подключениях</div>';
      document.getElementById('ustat-nodes').innerHTML = '';
      return;
    }
    var html = '<div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">';
    html += '<div style="background:var(--bg3);border-radius:8px;padding:12px;text-align:center">';
    html += '<div style="font-size:11px;color:var(--muted)">⚡ VLESS</div>';
    html += '<div style="font-size:18px;font-weight:700;color:var(--accent)">'+fmtBytes((s.vless||0))+'</div></div>';
    html += '<div style="background:var(--bg3);border-radius:8px;padding:12px;text-align:center">';
    html += '<div style="font-size:11px;color:var(--muted)">🚀 Hysteria2</div>';
    html += '<div style="font-size:18px;font-weight:700;color:var(--cyan)">'+fmtBytes((s.hysteria2||0))+'</div></div>';
    html += '</div>';
    document.getElementById('ustat-proto').innerHTML = html;
    var nhtml = '<div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:8px">';
    if(s.nodes) Object.keys(s.nodes).forEach(function(n){
      nhtml += '<div style="background:var(--bg3);border-radius:8px;padding:12px;text-align:center">';
      nhtml += '<div style="font-size:11px;color:var(--muted)">🖥 '+n+'</div>';
      nhtml += '<div style="font-size:16px;font-weight:700">'+fmtBytes(s.nodes[n])+'</div></div>';
    });
    nhtml += '</div>';
    document.getElementById('ustat-nodes').innerHTML = nhtml;
  });
  openModal('modal-user-stats');
}

function cpKey(text){
  copyText(text);
  toast('✅ Ключ скопирован!');
}

// === GLOBALS ===
window.openModal = openModal;
window.closeModal = closeModal;
window.cpKey = cpKey;
window.copyAllKeys = copyAllKeys;
window.pingNode = pingNode;
window.delNode = delNode;
window.delBridge = delBridge;
window.editHost = editHost;
window.delHost = delHost;
window.delAdmin = delAdmin;
window.delBot = delBot;
window.showKeys = showKeys;
window.showUserStats = showUserStats;
window.filterUsers = filterUsers;
window.exportUsers = exportUsers;
window.importUsers = importUsers;
window.createTemplate = createTemplate;
window.deleteTemplate = deleteTemplate;
window.useTemplate = useTemplate;
function editInbound(tag){
  api('GET','/inbounds').then(function(inbounds){
    var ib = (inbounds||[]).find(function(x){return x.tag===tag;});
    if(!ib) return;
    var tls=ib.raw.tls||{}, reality=tls.reality||{};
    document.getElementById('edit-ib-tag').value=tag;
    document.getElementById('edit-ib-port').value=ib.port;
    document.getElementById('edit-ib-listen').value=ib.listen||'::';
    document.getElementById('edit-ib-sni').value=tls.server_name||'';
    if(reality.handshake){document.getElementById('edit-ib-hs-server').value=reality.handshake.server||'';document.getElementById('edit-ib-hs-port').value=reality.handshake.server_port||443;}
    if(reality.short_id) document.getElementById('edit-ib-shortid').value=(reality.short_id||[''])[0];
    openModal('modal-inbound-edit');
  });
}
window.editInbound = editInbound;
window.loadChart = loadChart;

function loadAuditPage(){
  api('GET','/logs?limit=200').then(function(rows){
    var el = document.getElementById('audit-page-list');
    if(!el) return;
    if(!rows||!rows.length){
      el.innerHTML='<div style="color:var(--muted);text-align:center;padding:40px">Лог пуст</div>';
      return;
    }
    var html='<div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;overflow:hidden">';
    html+='<table style="width:100%;border-collapse:collapse">';
    html+='<thead><tr style="background:var(--bg3)">';
    html+='<th style="padding:10px 16px;text-align:left;font-size:11px;color:var(--muted);font-weight:700">ВРЕМЯ</th>';
    html+='<th style="padding:10px 16px;text-align:left;font-size:11px;color:var(--muted);font-weight:700">АДМИН</th>';
    html+='<th style="padding:10px 16px;text-align:left;font-size:11px;color:var(--muted);font-weight:700">ДЕЙСТВИЕ</th>';
    html+='<th style="padding:10px 16px;text-align:left;font-size:11px;color:var(--muted);font-weight:700">ДЕТАЛИ</th>';
    html+='</tr></thead><tbody>';
    rows.forEach(function(r,i){
      var d=new Date(r.created_at*1000);
      var dt=d.toLocaleDateString('ru')+' '+d.toLocaleTimeString('ru');
      var bg=i%2===0?'var(--bg2)':'var(--bg3)';
      html+='<tr style="background:'+bg+';border-top:1px solid var(--border)">';
      html+='<td style="padding:10px 16px;font-size:12px;color:var(--muted);white-space:nowrap">'+dt+'</td>';
      html+='<td style="padding:10px 16px;font-size:13px"><b style="color:var(--accent)">'+r.admin+'</b></td>';
      html+='<td style="padding:10px 16px;font-size:13px">'+r.action+'</td>';
      html+='<td style="padding:10px 16px;font-size:12px;color:var(--muted)">'+((r.details&&r.details!=='null')?r.details:'')+'</td>';
      html+='</tr>';
    });
    html+='</tbody></table></div>';
    el.innerHTML=html;
  });
  // Загружаем autodiag лог
  api('GET','/logs/autodiag').then(function(r){
    var el2 = document.getElementById('autodiag-log');
    if(!el2) return;
    if(!r || !r.lines || !r.lines.length){
      el2.innerHTML='<span style="color:var(--muted)">Лог пуст — всё работает нормально</span>';
      return;
    }
    el2.innerHTML = r.lines.map(function(l){
      var color = l.includes('❌')?'var(--red)':l.includes('⚠️')?'var(--yellow)':l.includes('✅')?'var(--green)':'var(--muted)';
      return '<div style="color:'+color+';padding:2px 0;border-bottom:1px solid var(--border)">'+l+'</div>';
    }).join('');
  });
}
window.loadAuditPage = loadAuditPage;
var _btnAuditRefresh = document.getElementById('btn-audit-refresh');
if(_btnAuditRefresh) _btnAuditRefresh.addEventListener('click', loadAuditPage);

window.loadAudit = loadAudit;
window.changeMainPass = changeMainPass;

// loaders с inbounds и audit

window.toast = toast;
window.copyText = copyText;
window.copyAllKeys = copyAllKeys;
window.showKeys = showKeys;
window.showUserStats = showUserStats;
window.openModal = openModal;
window.closeModal = closeModal;
})();
</script>

<!-- Modal User Stats -->
<div class="modal-overlay" id="modal-user-stats" onclick="if(event.target===this)closeModal('modal-user-stats')">
  <div class="modal" style="max-width:480px">
    <div class="modal-header">
      <div class="modal-title">📊 Статистика: <span id="ustat-name"></span></div>
      <button class="modal-close" onclick="closeModal('modal-user-stats')">✕</button>
    </div>
    <div class="modal-body">
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:16px">
        <div style="background:var(--bg3);border-radius:8px;padding:12px">
          <div style="font-size:11px;color:var(--muted)">Статус</div>
          <div style="font-weight:700" id="ustat-status">—</div>
        </div>
        <div style="background:var(--bg3);border-radius:8px;padding:12px">
          <div style="font-size:11px;color:var(--muted)">Истекает</div>
          <div style="font-weight:700" id="ustat-expire">—</div>
        </div>
        <div style="background:var(--bg3);border-radius:8px;padding:12px">
          <div style="font-size:11px;color:var(--muted)">Использовано</div>
          <div style="font-weight:700" id="ustat-traffic">—</div>
        </div>
        <div style="background:var(--bg3);border-radius:8px;padding:12px">
          <div style="font-size:11px;color:var(--muted)">Лимит</div>
          <div style="font-weight:700" id="ustat-limit">—</div>
        </div>
      </div>
      <div style="font-size:12px;color:var(--muted);margin-bottom:8px;font-weight:700">ПО ПРОТОКОЛАМ</div>
      <div id="ustat-proto"></div>
      <div style="font-size:12px;color:var(--muted);margin-top:12px;margin-bottom:4px;font-weight:700">ПО НОДАМ</div>
      <div id="ustat-nodes"></div>
    </div>
  </div>
</div>

</body>
</html>

FILEEOF
echo '✅ Все файлы успешно развернуты в /opt/vpn_panel/'
