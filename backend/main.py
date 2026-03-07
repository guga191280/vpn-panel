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
    import secrets as _st
    _sub_tok_new = _st.token_urlsafe(24)
    _domain = get_db().execute("SELECT value FROM settings WHERE key='panel_domain'").fetchone()
    _domain = _domain[0] if _domain else 'localhost'
    sub_url = f"https://{_domain}/sub/{_sub_tok_new}"
    sub_tok = _sub_tok_new
    hy2_url = keys.get("hy2_main", keys.get("hysteria2", ""))
    vless_ru75 = keys.get("vless_fin", keys.get("vless_ru75", ""))
    hy2_ru75 = keys.get("hy2_fin", keys.get("hy2_ru75", ""))
    # Собираем все bridge ключи
    bridge_keys = {k:v for k,v in keys.items() if 'bridge' in k}
    vless_bridge = next((v for k,v in bridge_keys.items() if 'vless' in k), '')
    hy2_bridge = next((v for k,v in bridge_keys.items() if 'hy2' in k), '')
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
        db = get_db()
        nodes = db.execute("SELECT host FROM nodes WHERE status='online'").fetchall()
        db.close()
        total_conns = 0
        all_ips = set()
        for node in nodes:
            host = node['host']
            if host in ('185.40.4.169',): host = '127.0.0.1'
            try:
                r = req.get(f"http://{host}:9090/connections", timeout=3)
                if r.status_code == 200:
                    conns = r.json().get("connections", [])
                    total_conns += len(conns)
                    for c in conns:
                        ip = c.get("metadata",{}).get("sourceIP","")
                        if ip: all_ips.add(ip)
            except: pass
        return {"count": total_conns, "unique_users": len(all_ips)}
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
    bridges = conn.execute("SELECT * FROM bridges WHERE status='active'").fetchall()
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
    conn.execute("UPDATE bridges SET status='inactive' WHERE id=?", (bridge_id,))
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
            nodes = conn.execute("SELECT id, host, api_port, api_token FROM nodes WHERE status != 'installing' AND id != 'main'").fetchall()
            # Главная нода всегда online
            conn.execute("UPDATE nodes SET status='online' WHERE id='main'")
            conn.commit()
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
    import uuid as uuid_lib, time as t, sys, json, secrets as _sec
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
    
    # Генерируем sub_token
    sub_token = _sec.token_urlsafe(24)
    
    # Получаем domain
    _db = get_db()
    _dom = _db.execute("SELECT value FROM settings WHERE key='panel_domain'").fetchone()
    _db.close()
    domain = _dom[0] if _dom else 'panel.alexanderoff.ru'
    sub_url = f"https://{domain}/sub/{sub_token}"
    
    keys = keygen.generate_keys(user_id)
    # Маппинг ключей из keygen
    vless_de  = next((v for k,v in keys.items() if 'vless' in k.lower() and 'de' in k.lower() and 'bridge' not in k.lower()), "")
    hy2_de    = next((v for k,v in keys.items() if 'hy2' in k.lower() and 'de' in k.lower() and 'bridge' not in k.lower()), "")
    vless_fin = next((v for k,v in keys.items() if 'vless' in k.lower() and 'fin' in k.lower()), "")
    hy2_fin   = next((v for k,v in keys.items() if 'hy2' in k.lower() and 'fin' in k.lower() and 'bridge' not in k.lower()), "")
    hy2_br_de = next((v for k,v in keys.items() if 'bridge' in k.lower() and 'de' in k.lower()), "")
    hy2_br_fin= next((v for k,v in keys.items() if 'bridge' in k.lower() and 'fin' in k.lower()), "")

    conn = get_db()
    try:
        conn.execute("""INSERT INTO users 
            (id,username,telegram_id,status,data_limit,expire_at,
             subscription_url,hysteria2_url,vless_ru75,hy2_ru75,
             vless_main_bridge,hy2_main_bridge,node_ids,created_at,note,sub_token,vless_de)
            VALUES (?,?,?,'active',?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (user_id, username, telegram_id, data_limit, expire_at,
             sub_url, hy2_de, vless_fin, hy2_fin, hy2_br_de, hy2_br_fin,
             json.dumps([]), int(t.time()), "", sub_token, vless_de))
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
        "sub_token": sub_token,
        "sub_url": sub_url,
        "keys": {
            "vless_de": vless_de,
            "hy2_de": hy2_de,
            "vless_fin": vless_fin,
            "hy2_fin": hy2_fin,
            "hy2_bridge_de": hy2_br_de,
            "hy2_bridge_fin": hy2_br_fin
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
    sub_token = u.get("sub_token","")
    sub_url = u.get("subscription_url","")
    # Если sub_url не https - исправим
    if sub_token and not sub_url.startswith("https://"):
        import sqlite3 as _sq
        _db2 = get_db()
        _dom2 = _db2.execute("SELECT value FROM settings WHERE key='panel_domain'").fetchone()
        _db2.close()
        domain2 = _dom2[0] if _dom2 else 'panel.alexanderoff.ru'
        sub_url = f"https://{domain2}/sub/{sub_token}"
    return {
        "success": True,
        "user_id": u["id"],
        "username": u["username"],
        "status": u["status"],
        "sub_token": sub_token,
        "sub_url": sub_url,
        "keys": {
            "vless_de": u.get("vless_de",""),
            "hy2_de": u.get("hysteria2_url",""),
            "vless_fin": u.get("vless_ru75",""),
            "hy2_fin": u.get("hy2_ru75",""),
            "hy2_bridge_de": u.get("vless_main_bridge",""),
            "hy2_bridge_fin": u.get("hy2_main_bridge","")
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
    sub_url = f"https://{domain}/sub/{sub_tok['sub_token']}" if sub_tok and sub_tok['sub_token'] else ""
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

