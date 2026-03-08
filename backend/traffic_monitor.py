import time, sqlite3, socket, threading, sys, os
from pathlib import Path
import grpc
from grpc_tools import protoc as _protoc

DB_PATH = Path(__file__).parent / "vpn_panel.db"
BRIDGE_UUID = '3b5ba9bb-c766-46a4-8485-a3a5e2bddaeb'
V2RAY_API_PORT = 8388
NODE_CONFIGS = [
    {'key': 'russia', 'host': '212.15.49.151',  'password': 'PVJXSWnS6ZXUg', 'local_port': 18381},
    {'key': 'de',     'host': '150.241.106.238', 'password': 'alexander77',    'local_port': 18382},
    {'key': 'fin',    'host': '150.241.88.243',  'password': 'alexander77',    'local_port': 18383},
]
_ssh_clients = {}
_tunnel_servers = {}
_grpc = None
_stats_pb2 = None
_stats_pb2_grpc = None

def init_proto():
    global _grpc, _stats_pb2, _stats_pb2_grpc
    if _grpc:
        return True
    try:
        _grpc = grpc
        proto_dir = '/tmp/vpn_stats_proto'
        os.makedirs(proto_dir, exist_ok=True)
        with open(f'{proto_dir}/stats.proto', 'w') as f:
            f.write('syntax = "proto3";\npackage v2ray.core.app.stats.command;\nservice StatsService {\n  rpc QueryStats(QueryStatsRequest) returns (QueryStatsResponse);\n}\nmessage QueryStatsRequest {\n  string pattern = 1;\n  bool reset = 2;\n}\nmessage QueryStatsResponse {\n  repeated Stat stat = 1;\n}\nmessage Stat {\n  string name = 1;\n  int64 value = 2;\n}\n')
        import subprocess
        r = subprocess.run(['python3', '-m', 'grpc_tools.protoc', f'-I{proto_dir}', f'--python_out={proto_dir}', f'--grpc_python_out={proto_dir}', f'{proto_dir}/stats.proto'], capture_output=True)
        if r.returncode != 0:
            print(f"Proto error: {r.stderr.decode()}")
            return False
        sys.path.insert(0, proto_dir)
        import stats_pb2, stats_pb2_grpc
        _stats_pb2 = stats_pb2
        _stats_pb2_grpc = stats_pb2_grpc
        print("grpc proto OK")
        return True
    except Exception as e:
        print(f"init_proto error: {e}")
        return False

def get_ssh(host, password):
    import paramiko
    try:
        if host in _ssh_clients:
            _ssh_clients[host].exec_command('echo ok')[1].read()
            return _ssh_clients[host]
    except:
        pass
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, username='root', password=password, timeout=10)
    _ssh_clients[host] = c
    return c

def ensure_tunnel(node):
    host = node['host']
    local_port = node['local_port']
    try:
        s = socket.socket()
        s.settimeout(1)
        s.connect(('127.0.0.1', local_port))
        s.close()
        return True
    except:
        pass
    try:
        ssh = get_ssh(host, node['password'])
        transport = ssh.get_transport()
        if host in _tunnel_servers:
            try: _tunnel_servers[host].close()
            except: pass
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(('127.0.0.1', local_port))
        srv.listen(5)
        srv.settimeout(1)
        _tunnel_servers[host] = srv
        def handle(ls):
            try:
                ch = transport.open_channel('direct-tcpip', ('127.0.0.1', V2RAY_API_PORT), ('127.0.0.1', local_port))
                def fwd(s, d):
                    try:
                        while True:
                            data = s.recv(4096)
                            if not data: break
                            d.send(data)
                    except: pass
                threading.Thread(target=fwd, args=(ls, ch), daemon=True).start()
                threading.Thread(target=fwd, args=(ch, ls), daemon=True).start()
            except: pass
        def loop():
            while True:
                try:
                    conn, _ = srv.accept()
                    threading.Thread(target=handle, args=(conn,), daemon=True).start()
                except socket.timeout: continue
                except: break
        threading.Thread(target=loop, daemon=True).start()
        time.sleep(0.5)
        return True
    except Exception as e:
        print(f"  tunnel {host}: {e}")
        return False

def query_user_traffic(local_port, reset=True):
    try:
        ch = _grpc.insecure_channel(f'127.0.0.1:{local_port}')
        stub = _stats_pb2_grpc.StatsServiceStub(ch)
        resp = stub.QueryStats(_stats_pb2.QueryStatsRequest(pattern='user>>>', reset=reset), timeout=5)
        ch.close()
        result = {}
        for s in resp.stat:
            if s.value <= 0: continue
            parts = s.name.split('>>>')
            if len(parts) == 4 and parts[0] == 'user' and parts[2] == 'traffic':
                uuid = parts[1]
                if uuid == BRIDGE_UUID: continue
                result[uuid] = result.get(uuid, 0) + s.value
        return result
    except Exception as e:
        print(f"  grpc {local_port}: {e}")
        return {}

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def collect_and_save():
    if not init_proto(): return
    total = {}
    for node in NODE_CONFIGS:
        try:
            if not ensure_tunnel(node): continue
            traffic = query_user_traffic(node['local_port'], reset=True)
            if traffic:
                print(f"  [{node['key']}] {len(traffic)} users {round(sum(traffic.values())/1024,1)}KB")
                for uuid, d in traffic.items():
                    total[uuid] = total.get(uuid, 0) + d
        except Exception as e:
            print(f"  [{node['key']}] error: {e}")
    if not total: return
    db = get_db()
    try:
        upd = 0
        for uuid, delta in total.items():
            if delta <= 0: continue
            r = db.execute("UPDATE users SET data_used=data_used+? WHERE id=? AND status IN ('active','overlimit')", (delta, uuid))
            if r.rowcount > 0: upd += 1
        over = db.execute("SELECT id,username FROM users WHERE data_limit>0 AND data_used>=data_limit AND status='active'").fetchall()
        for u in over:
            db.execute("UPDATE users SET status='overlimit' WHERE id=?", (u['id'],))
            print(f"  🚫 {u['username']} overlimit")
        db.commit()
        if upd > 0:
            print(f"  💾 {upd} users saved, {round(sum(total.values())/1024/1024,3)}MB total")
    finally:
        db.close()

def monitor_loop():
    print("🚀 Traffic monitor v4 (V2Ray Stats)")
    if not init_proto():
        print("❌ gRPC init failed")
        return
    print("Connecting to nodes...")
    for node in NODE_CONFIGS:
        if ensure_tunnel(node):
            query_user_traffic(node['local_port'], reset=True)
            print(f"  ✅ {node['key']} OK")
        else:
            print(f"  ❌ {node['key']} failed")
    print()
    while True:
        try:
            print(f"🔄 [{time.strftime('%H:%M:%S')}]")
            collect_and_save()
        except Exception as e:
            print(f"❌ {e}")
        time.sleep(30)

if __name__ == '__main__':
    monitor_loop()
