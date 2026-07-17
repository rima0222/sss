#!/usr/bin/env bash
# ==============================================================================
# SSH Management Panel - High-Engineering Installation Script
# Designed for: Amir
# Features: WAL SQLite, Precise /proc/<pid>/io Traffic Tracking, Systemd Daemons, Toast UI
# Port: 8000
# ==============================================================================

# Coloured outputs
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== شروع فرآیند نصب مهندسی‌شده پنل مدیریت کاربران ===${NC}"

# 1. Install System Requirements
echo -e "${GREEN}[1/5] در حال نصب پیش‌نیازها...${NC}"
apt-get update -y && apt-get install -y python3 python3-pip python3-flask sqlite3 procps lsof -y || true

# Create directory structures
mkdir -p /var/lib/ssh-panel/app
mkdir -p /var/lib/ssh-panel/templates
mkdir -p /var/lib/ssh-panel/static

# 2. Database Initialization with WAL Mode
echo -e "${GREEN}[2/5] راه‌اندازی پایگاه داده امن...${NC}"
DB_PATH="/var/lib/ssh-panel/database.db"

sqlite3 "$DB_PATH" <<EOF
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS users (
    username TEXT PRIMARY KEY,
    password TEXT NOT NULL,
    total_volume REAL NOT NULL,
    used_traffic REAL DEFAULT 0.0,
    remaining_time INTEGER NOT NULL,
    status TEXT DEFAULT 'active'
);
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT
);
INSERT OR IGNORE INTO settings (key, value) VALUES ('admin_user', 'admin');
INSERT OR IGNORE INTO settings (key, value) VALUES ('admin_pass', 'admin');
INSERT OR IGNORE INTO settings (key, value) VALUES ('ssh_ws_port', '80');
EOF

# 3. Intelligent Traffic & Session Monitor Daemon
echo -e "${GREEN}[3/5] ایجاد سرویس مانیتورینگ ترافیک (/proc/pid/io)...${NC}"
cat <<'EOF' > /var/lib/ssh-panel/worker.py
import os
import sys
import time
import sqlite3
import subprocess

DB_PATH = "/var/lib/ssh-panel/database.db"

def get_db():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL;")
    return conn

pid_io_cache = {}

def get_user_pids():
    user_pids = {}
    try:
        conn = get_db()
        users = [row[0] for row in conn.execute("SELECT username FROM users").fetchall()]
        conn.close()
    except Exception:
        return {}

    for user in users:
        try:
            pids_str = subprocess.check_output(["pgrep", "-u", user]).decode().strip()
            if pids_str:
                user_pids[user] = [int(p) for p in pids_str.split()]
        except subprocess.CalledProcessError:
            continue
    return user_pids

def update_traffic_and_status():
    global pid_io_cache
    user_pids = get_user_pids()
    active_online_users = []

    conn = get_db()
    
    restricted_users = [row[0] for row in conn.execute("SELECT username FROM users WHERE status != 'active'").fetchall()]
    
    for user in restricted_users:
        if user in user_pids:
            subprocess.run(f"pkill -u {user}", shell=True)

    current_pids_seen = set()
    for user, pids in user_pids.items():
        user_bytes = 0
        is_online = False
        
        for pid in pids:
            current_pids_seen.add(pid)
            try:
                with open(f"/proc/{pid}/io", "r") as f:
                    lines = f.readlines()
                read_bytes = 0
                write_bytes = 0
                for line in lines:
                    if line.startswith("read_bytes:"):
                        read_bytes = int(line.split()[1])
                    elif line.startswith("write_bytes:"):
                        write_bytes = int(line.split()[1])
                
                total_io = read_bytes + write_bytes
                
                if pid in pid_io_cache:
                    diff = total_io - pid_io_cache[pid]
                    if diff > 0:
                        user_bytes += diff
                else:
                    pid_io_cache[pid] = total_io
                
                is_online = True
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                continue

        if is_online:
            active_online_users.append(user)

        if user_bytes > 0:
            user_gb = user_bytes / (1024 ** 3)
            conn.execute("UPDATE users SET used_traffic = used_traffic + ? WHERE username = ?", (user_gb, user))
            conn.commit()

    for dead_pid in list(pid_io_cache.keys()):
        if dead_pid not in current_pids_seen:
            pid_io_cache.pop(dead_pid, None)

    users_data = conn.execute("SELECT username, total_volume, used_traffic, remaining_time FROM users WHERE status='active'").fetchall()
    for username, total_volume, used_traffic, remaining_time in users_data:
        new_time = max(0, remaining_time - 10)
        conn.execute("UPDATE users SET remaining_time = ? WHERE username = ?", (new_time, username))
        
        if used_traffic >= total_volume:
            conn.execute("UPDATE users SET status = 'expired' WHERE username = ?", (username,))
            subprocess.run(f"usermod -L {username}", shell=True)
            subprocess.run(f"pkill -u {username}", shell=True)
        elif new_time <= 0:
            conn.execute("UPDATE users SET status = 'expired' WHERE username = ?", (username,))
            subprocess.run(f"usermod -L {username}", shell=True)
            subprocess.run(f"pkill -u {username}", shell=True)

    conn.commit()
    conn.close()

if __name__ == "__main__":
    while True:
        try:
            update_traffic_and_status()
        except Exception as e:
            pass
        time.sleep(10)
EOF

# 4. Web Server & API Panel Development
echo -e "${GREEN}[4/5] پیکربندی وب‌سرور کنترل پنل...${NC}"

cat <<'EOF' > /var/lib/ssh-panel/app/routes.py
import sqlite3
import subprocess
from flask import Blueprint, render_template, request, jsonify

bp = Blueprint('routes', __name__)
DB_PATH = "/var/lib/ssh-panel/database.db"

def get_db():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL;")
    return conn

@bp.route('/')
def index():
    conn = get_db()
    users_rows = conn.execute("SELECT username, password, total_volume, used_traffic, remaining_time, status FROM users").fetchall()
    
    admin_user = conn.execute("SELECT value FROM settings WHERE key='admin_user'").fetchone()[0]
    ssh_ws_port = conn.execute("SELECT value FROM settings WHERE key='ssh_ws_port'").fetchone()[0]
    
    users = []
    total_used = 0.0
    total_allowed_vol = 0.0
    active_count = 0
    online_count = 0
    
    online_users = []
    for row in users_rows:
        username = row[0]
        try:
            subprocess.check_output(["pgrep", "-u", username])
            online_users.append(username)
        except subprocess.CalledProcessError:
            pass

    for row in users_rows:
        username, password, total_vol, used, rem_time, status = row
        total_used += used
        total_allowed_vol += total_vol
        if status == 'active':
            active_count += 1
            
        is_online = username in online_users
        if is_online:
            online_count += 1
            
        days_left = max(0, int(rem_time / 86400))
        readable_time = f"{days_left} روز" if days_left > 0 else "منقضی شده"
        
        users.append({
            "username": username,
            "password": password,
            "total_volume": round(total_vol, 2),
            "used_download": round(used, 2),
            "remaining_time": rem_time,
            "readable_time": readable_time,
            "status": status,
            "is_online": is_online
        })
        
    conn.close()
    
    try:
        ram_usage = subprocess.check_output("free -m | awk 'NR==2{printf \"%.1f%%\", $3*100/$2 }'", shell=True).decode().strip()
    except Exception:
        ram_usage = "N/A"
        
    return render_template("index.html", 
                           users=users,
                           admin_user=admin_user,
                           ssh_ws_port=ssh_ws_port,
                           total_used=round(total_used, 2),
                           total_allowed_vol=round(total_allowed_vol, 2),
                           active_count=active_count,
                           online_count=online_count,
                           total_users_count=len(users),
                           ram_usage=ram_usage)

@bp.route('/api/user/add', methods=['POST'])
def add_user():
    data = request.json
    u, p, vol, r_time = data['username'].strip(), data['password'].strip(), float(data['total_volume']), int(data['remaining_time'])
    conn = get_db()
    try:
        conn.execute("INSERT INTO users (username, password, total_volume, remaining_time, status, used_traffic) VALUES (?, ?, ?, ?, 'active', 0.0)", (u, p, vol, r_time))
        conn.commit()
        subprocess.run(f"useradd -M -s /usr/sbin/nologin {u}", shell=True)
        subprocess.run(f"echo '{u}:{p}' | chpasswd", shell=True)
        success = True
    except Exception:
        success = False
    finally:
        conn.close()
    return jsonify({"success": success})

@bp.route('/api/user/edit', methods=['POST'])
def edit_user():
    data = request.json
    u, p, vol, r_time = data['username'].strip(), data['password'].strip(), float(data['total_volume']), int(data['remaining_time'])
    conn = get_db()
    conn.execute("UPDATE users SET password=?, total_volume=?, remaining_time=?, status='active' WHERE username=?", (p, vol, r_time, u))
    conn.commit()
    conn.close()
    subprocess.run(f"usermod -U {u}", shell=True)
    subprocess.run(f"echo '{u}:{p}' | chpasswd", shell=True)
    return jsonify({"success": True})

@bp.route('/api/user/pause', methods=['POST'])
def pause_user():
    u = request.json['username']
    conn = get_db()
    conn.execute("UPDATE users SET status='paused' WHERE username=?", (u,))
    conn.commit()
    conn.close()
    subprocess.run(f"usermod -L {u}", shell=True)
    subprocess.run(f"pkill -u {u}", shell=True)
    return jsonify({"success": True})

@bp.route('/api/user/resume', methods=['POST'])
def resume_user():
    u = request.json['username']
    conn = get_db()
    conn.execute("UPDATE users SET status='active' WHERE username=?", (u,))
    conn.commit()
    conn.close()
    subprocess.run(f"usermod -U {u}", shell=True)
    return jsonify({"success": True})

@bp.route('/api/user/reset', methods=['POST'])
def reset_user():
    u = request.json['username']
    conn = get_db()
    conn.execute("UPDATE users SET used_traffic=0.0 WHERE username=?", (u,))
    conn.commit()
    conn.close()
    return jsonify({"success": True})

@bp.route('/api/user/delete', methods=['POST'])
def delete_user():
    u = request.json['username']
    conn = get_db()
    conn.execute("DELETE FROM users WHERE username=?", (u,))
    conn.commit()
    conn.close()
    subprocess.run(f"userdel -f {u}", shell=True)
    subprocess.run(f"pkill -u {u}", shell=True)
    return jsonify({"success": True})

@bp.route('/api/settings/save', methods=['POST'])
def save_settings():
    data = request.json
    admin_user = data['admin_user']
    admin_pass = data['admin_pass']
    ssh_ws_port = data['ssh_ws_port']
    
    conn = get_db()
    conn.execute("UPDATE settings SET value=? WHERE key='admin_user'", (admin_user,))
    conn.execute("UPDATE settings SET value=? WHERE key='ssh_ws_port'", (ssh_ws_port,))
    if admin_pass:
        conn.execute("UPDATE settings SET value=? WHERE key='admin_pass'", (admin_pass,))
    conn.commit()
    conn.close()
    
    subprocess.run("systemctl restart ssh-pro-ws || true", shell=True)
    return jsonify({"success": True})
EOF

# 5. Create Flask Entrypoint App Runner (Port changed to 8000)
cat <<'EOF' > /var/lib/ssh-panel/run.py
from flask import Flask
from app.routes import bp

app = Flask(__name__, 
            template_folder='/var/lib/ssh-panel/templates',
            static_folder='/var/lib/ssh-panel/static')
app.secret_key = "highly_engineered_secure_key"
app.register_blueprint(bp)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000, debug=False)
EOF

# 6. Service Registrations for Permanent Uptime
echo -e "${GREEN}[5/5] ثبت سرویس‌های پس‌زمینه (Systemd Services)...${NC}"

cat <<'EOF' > /etc/systemd/system/ssh-pro-worker.service
[Unit]
Description=SSH Core Traffic and Expiry Monitor
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/ssh-panel
ExecStart=/usr/bin/python3 /var/lib/ssh-panel/worker.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' > /etc/systemd/system/ssh-pro-panel.service
[Unit]
Description=SSH Management Web Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/ssh-panel
ExecStart=/usr/bin/python3 /var/lib/ssh-panel/run.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Reload and Restart Services safely
systemctl daemon-reload
systemctl enable ssh-pro-worker.service
systemctl enable ssh-pro-panel.service
systemctl restart ssh-pro-worker.service
systemctl restart ssh-pro-panel.service

echo -e "${GREEN}=== نصب با موفقیت پایان یافت! ===${NC}"
echo -e "${GREEN}آدرس دسترسی به پنل: http://YOUR_SERVER_IP:8000${NC}"
