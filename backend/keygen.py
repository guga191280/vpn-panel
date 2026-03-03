import sqlite3, json, re

SERVERS = {
    'main': {
        'ip': '185.40.4.169',
        'public_key': 'diBwtDOuRYN7u8SIGdqPuuPaxCW1jffoX2iAfBa4zgo',
        'short_id': 'a2370edeeb960dcf',
        'name': 'Russia'
    },
    'fin': {
        'ip': 'fin243.alexanderoff.store',
        'public_key': '8P9hgA8IlnvXq3qJU1R7lOqiqYEVXD1zb5CUP_u26S8',
        'short_id': 'fd4c0594777d0d1b',
        'name': 'Finland'
    }
}
BRIDGES = {}

def load_bridges():
    global BRIDGES
    try:
        conn = sqlite3.connect('/opt/vpn_panel/backend/vpn_panel.db')
        conn.row_factory = sqlite3.Row
        rows = conn.execute('SELECT * FROM bridges').fetchall()
        conn.close()
        BRIDGES = {}
        for r in rows:
            r = dict(r)
            BRIDGES[str(r['id'])] = r
    except Exception as e:
        print('load_bridges error:', e)
        BRIDGES = {}

def vless(uuid, server_id='main'):
    s = SERVERS.get(server_id, SERVERS['main'])
    return (f"vless://{uuid}@{s['ip']}:443"
            f"?encryption=none&flow=xtls-rprx-vision&security=reality"
            f"&sni=www.microsoft.com&fp=chrome"
            f"&pbk={s['public_key']}&sid={s['short_id']}"
            f"&type=tcp&headerType=none#{s['name']}-VLESS")

def hy2(uuid, server_id='main'):
    s = SERVERS.get(server_id, SERVERS['main'])
    return (f"hysteria2://{uuid}@{s['ip']}:20897"
            f"?insecure=1&sni={s['ip']}#{s['name']}-HY2")

def generate_keys(uuid):
    load_bridges()
    keys = {}
    for sid, s in SERVERS.items():
        keys[f'vless_{sid}'] = vless(uuid, sid)
        keys[f'hy2_{sid}'] = hy2(uuid, sid)
    for bid, b in BRIDGES.items():
        if not b.get('active', 0): continue
        # Используем foreign_ip как адрес для подключения
        foreign = b.get('foreign_ip', '')
        ru_ip = b.get('ru_ip', '')
        if foreign and ru_ip:
            keys[f'vless_{bid}_bridge'] = (
                f"vless://{uuid}@{ru_ip}:443?encryption=none&flow=xtls-rprx-vision"
                f"&security=reality&sni=www.microsoft.com&fp=chrome"
                f"&pbk={SERVERS['main']['public_key']}&sid={SERVERS['main']['short_id']}"
                f"&type=tcp&headerType=none#Bridge-{bid}-VLESS"
            )
            keys[f'hy2_{bid}_bridge'] = (
                f"hysteria2://{uuid}@{ru_ip}:20897"
                f"?insecure=1&sni={ru_ip}#Bridge-{bid}-HY2"
            )
    return keys
