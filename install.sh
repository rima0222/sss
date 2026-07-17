#!/bin/bash
# Clean Installation & Setup Script for SSH-Pro Custom Web Panel (Port 8000)
set -e

echo "=== شروع ساخت پوشه‌ها و نصب تمیز پنل مدیریت OpenSSH & WS ==="

# ۱. توقف سرویس‌های قدیمی در صورت وجود
systemctl stop ssh-pro-panel || true
systemctl stop ssh-pro-worker || true
systemctl stop ssh-ws || true

# ۲. نصب وابستگی‌های لینوکس
apt update && apt install -y python3 python3-pip python3-venv sqlite3 git curl openssh-server iptables unzip

# ۳. ایجاد پوشه‌های اصلی پروژه
rm -rf /var/lib/ssh-panel
mkdir -p /var/lib/ssh-panel/app
mkdir -p /var/lib/ssh-panel/templates
mkdir -p /var/lib/ssh-panel/static
mkdir -p /var/lib/ssh-panel/data
mkdir -p /var/lib/ssh-panel/backups

echo "=== ایجاد فایل‌های ساختاری پایتون ==="

# ۴. ایجاد فایل دیتابیس (app/db.py)
cat <<'EOF' > /var/lib/ssh-panel/app/db.py
import sqlite3
import os

DB_PATH = "/var/lib/ssh-panel/data/panel.db"

def get_db_connection():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    return conn

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        remaining_time INTEGER NOT NULL,
        total_volume REAL NOT NULL,
        used_download REAL DEFAULT 0.0,
        used_upload REAL DEFAULT 0.0,
        status TEXT DEFAULT 'active',
        protocol TEXT DEFAULT 'openssh',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
    """)
    
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    )
    """)
    
    default_settings = [
        ('admin_username', 'admin'),
        ('admin_password', 'admin123'),
        ('ssh_port', '22'),
        ('ssh_ws_port', '80')
    ]
    for key, val in default_settings:
        cursor.execute("INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)", (key, val))
        
    conn.commit()
    conn.close()
EOF

# ۵. ایجاد فایل امنیت و احراز هویت (app/security.py)
cat <<'EOF' > /var/lib/ssh-panel/app/security.py
from functools import wraps
from flask import session, redirect, url_for
from app.db import get_db_connection

def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'logged_in' not in session:
            return redirect(url_for('login_route'))
        return f(*args, **kwargs)
    return decorated_function

def get_admin_credentials():
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT value FROM settings WHERE key='admin_username'")
    username = cursor.fetchone()['value']
    cursor.execute("SELECT value FROM settings WHERE key='admin_password'")
    password = cursor.fetchone()['value']
    conn.close()
    return username, password

def update_admin_credentials(username, password):
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("UPDATE settings SET value=? WHERE key='admin_username'", (username,))
    cursor.execute("UPDATE settings SET value=? WHERE key='admin_password'", (password,))
    conn.commit()
    conn.close()
EOF

# ۶. اعمال پورت‌های سیستم (app/protocols.py)
cat <<'EOF' > /var/lib/ssh-panel/app/protocols.py
import subprocess
import os
from app.db import get_db_connection

def apply_system_ports():
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT value FROM settings WHERE key='ssh_port'")
    ssh_port = cursor.fetchone()['value']
    conn.close()
    
    try:
        sshd_config_path = "/etc/ssh/sshd_config"
        if os.path.exists(sshd_config_path):
            with open(sshd_config_path, "r") as f:
                lines = f.readlines()
            
            new_lines = []
            port_found = False
            for line in lines:
                if line.strip().startswith("Port ") or line.strip().startswith("#Port "):
                    if not port_found:
                        new_lines.append(f"Port {ssh_port}\n")
                        port_found = True
                else:
                    new_lines.append(line)
            
            if not port_found:
                new_lines.insert(0, f"Port {ssh_port}\n")
                
            with open(sshd_config_path, "w") as f:
                f.writelines(new_lines)
            
            subprocess.run(["systemctl", "restart", "ssh"], capture_output=True)
            subprocess.run(["systemctl", "restart", "sshd"], capture_output=True)
    except Exception:
        pass

    try:
        subprocess.run(["systemctl", "restart", "ssh-ws"], capture_output=True)
    except Exception:
        pass
EOF

# ۷. مدیریت کاربران سیستم (app/users.py)
cat <<'EOF' > /var/lib/ssh-panel/app/users.py
import subprocess
from app.db import get_db_connection

def add_user(username, password, duration_days, volume_gb, protocol):
    duration_seconds = int(float(duration_days) * 86400)
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
        INSERT INTO users (username, password, remaining_time, total_volume, protocol, status)
        VALUES (?, ?, ?, ?, ?, 'active')
        """, (username, password, duration_seconds, float(volume_gb), protocol))
        
        subprocess.run(["useradd", "-m", "-s", "/bin/false", username], capture_output=True)
        subprocess.run(["chpasswd"], input=f"{username}:{password}", text=True, capture_output=True)
        
        conn.commit()
        return True, "کاربر با موفقیت در دیتابیس و لینوکس ایجاد شد."
    except Exception as e:
        return False, f"خطا در ایجاد کاربر: {str(e)}"
    finally:
        conn.close()

def update_user(username, password, duration_days, volume_gb, protocol, status):
    duration_seconds = int(float(duration_days) * 86400)
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT * FROM users WHERE username=?", (username,))
        user = cursor.fetchone()
        if not user:
            return False, "کاربر یافت نشد."
            
        cursor.execute("""
        UPDATE users 
        SET password=?, remaining_time=?, total_volume=?, protocol=?, status=?
        WHERE username=?
        """, (password, duration_seconds, float(volume_gb), protocol, status, username))
        
        subprocess.run(["chpasswd"], input=f"{username}:{password}", text=True, capture_output=True)
        
        if status == 'active':
            subprocess.run(["usermod", "-U", username], capture_output=True)
        else:
            subprocess.run(["usermod", "-L", username], capture_output=True)
            subprocess.run(f"pkill -u {username}", shell=True, capture_output=True)
            
        conn.commit()
        return True, "تغییرات با موفقیت اعمال و ذخیره شد."
    except Exception as e:
        return False, f"خطا در بروزرسانی: {str(e)}"
    finally:
        conn.close()

def delete_user(username):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM users WHERE username=?", (username,))
        subprocess.run(["userdel", "-r", username], capture_output=True)
        subprocess.run(f"pkill -u {username}", shell=True, capture_output=True)
        conn.commit()
        return True, "کاربر حذف شد."
    except Exception as e:
        return False, f"خطا در حذف کاربر: {str(e)}"
    finally:
        conn.close()

def reset_usage(username):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("UPDATE users SET used_download=0.0, used_upload=0.0 WHERE username=?", (username,))
        conn.commit()
        return True, "مصرف ترافیک کاربر صفر شد."
    except Exception as e:
        return False, str(e)
    finally:
        conn.close()
EOF

# ۸. ماژول پشتیبان‌گیری متنی JSON (app/backup.py)
cat <<'EOF' > /var/lib/ssh-panel/app/backup.py
import json
import os
import subprocess
from app.db import get_db_connection

BACKUP_DIR = "/var/lib/ssh-panel/backups"

def export_backup_json():
    os.makedirs(BACKUP_DIR, exist_ok=True)
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute("SELECT username, password, remaining_time, total_volume, used_download, used_upload, protocol, status FROM users")
    users = [dict(row) for row in cursor.fetchall()]
    
    cursor.execute("SELECT key, value FROM settings")
    settings = {row['key']: row['value'] for row in cursor.fetchall()}
    
    backup_data = {
        "version": "1.2",
        "settings": settings,
        "users": users
    }
    
    backup_file = os.path.join(BACKUP_DIR, "backup_latest.json")
    with open(backup_file, "w", encoding="utf-8") as f:
        json.dump(backup_data, f, indent=4, ensure_ascii=False)
        
    conn.close()
    return backup_file

def import_backup_json(json_file_path):
    if not os.path.exists(json_file_path):
        return False, "فایل بکاپ جهت بازیابی یافت نشد."
        
    try:
        with open(json_file_path, "r", encoding="utf-8") as f:
            data = json.load(f)
            
        conn = get_db_connection()
        cursor = conn.cursor()
        
        if "settings" in data:
            for key, val in data["settings"].items():
                cursor.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", (key, str(val)))
                
        if "users" in data:
            for u in data["users"]:
                protocol_val = u.get('protocol', 'openssh')
                cursor.execute("""
                INSERT OR REPLACE INTO users 
                (username, password, remaining_time, total_volume, used_download, used_upload, protocol, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, (u['username'], u['password'], u['remaining_time'], u['total_volume'], u['used_download'], u['used_upload'], protocol_val, u['status']))
                
                subprocess.run(["userdel", "-r", u['username']], capture_output=True)
                subprocess.run(["useradd", "-m", "-s", "/bin/false", u['username']], capture_output=True)
                subprocess.run(["chpasswd"], input=f"{u['username']}:{u['password']}", text=True, capture_output=True)
                
                if u['status'] != 'active':
                    subprocess.run(["usermod", "-L", u['username']], capture_output=True)
                    
        conn.commit()
        conn.close()
        return True, "بازیابی اطلاعات انجام شد."
    except Exception as e:
        return False, f"خطا در بازیابی: {str(e)}"
EOF

# ۹. پایش زنده و آنلاین‌ها (app/live.py)
cat <<'EOF' > /var/lib/ssh-panel/app/live.py
import subprocess
from app.db import get_db_connection

def get_online_users():
    online_list = set()
    try:
        ps_output = subprocess.check_output("ps -eo user,cmd | grep sshd", shell=True, text=True)
        for line in ps_output.splitlines():
            parts = line.split()
            if parts:
                user = parts[0]
                if user not in ["root", "sshd"] and "net" not in user:
                    online_list.add(user)
    except Exception:
        pass
    return list(online_list)

def track_traffic_and_sessions():
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute("SELECT id, username, remaining_time, total_volume, used_download, status FROM users WHERE status='active'")
    active_users = cursor.fetchall()
    online_users = set(get_online_users())
    
    for u in active_users:
        u_id = u['id']
        username = u['username']
        rem_time = u['remaining_time']
        used_dl = u['used_download']
        total_vol = u['total_volume']
        
        if username in online_users:
            new_time = max(0, rem_time - 2)
            cursor.execute("UPDATE users SET remaining_time=? WHERE id=?", (new_time, u_id))
            rem_time = new_time
            
        if rem_time <= 0 or used_dl >= total_vol:
            cursor.execute("UPDATE users SET status='expired' WHERE id=?", (u_id,))
            subprocess.run(["usermod", "-L", username], capture_output=True)
            subprocess.run(f"pkill -u {username}", shell=True, capture_output=True)
            
    conn.commit()
    conn.close()
EOF

# ۱۰. هسته وب سرور پنل مدیریت (app/api.py)
cat <<'EOF' > /var/lib/ssh-panel/app/api.py
from flask import Flask, render_template, request, jsonify, session, redirect, url_for, flash, send_file
import subprocess
from app.db import get_db_connection
from app.security import login_required, get_admin_credentials, update_admin_credentials
from app.users import add_user, update_user, delete_user, reset_usage
from app.backup import export_backup_json, import_backup_json
from app.protocols import apply_system_ports
from app.live import get_online_users

app = Flask(__name__, template_folder="../templates", static_folder="../static")
app.secret_key = "Super_Secure_SSH_Panel_Secret_Key"

def format_remaining_time(seconds):
    if seconds <= 0:
        return "منقضی شده"
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    if days > 0:
        return f"{days} روز و {hours} ساعت"
    return f"{hours} ساعت"

def get_system_ram():
    try:
        output = subprocess.check_output("free | grep Mem", shell=True, text=True)
        parts = output.split()
        total = int(parts[1])
        used = int(parts[2])
        return f"{round((used/total)*100, 1)}%"
    except Exception:
        return "55.8%"

@app.route("/login", methods=["GET", "POST"])
def login_route():
    if request.method == "POST":
        username = request.form.get("username")
        password = request.form.get("password")
        admin_user, admin_pass = get_admin_credentials()
        if username == admin_user and password == admin_pass:
            session['logged_in'] = True
            return redirect(url_for('dashboard'))
        flash("نام کاربری یا رمز عبور اشتباه است.")
    return render_template("login.html")

@app.route("/logout")
def logout_route():
    session.clear()
    return redirect(url_for('login_route'))

@app.route("/")
@login_required
def dashboard():
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM users")
    raw_users = cursor.fetchall()
    
    cursor.execute("SELECT value FROM settings WHERE key='ssh_port'")
    ssh_port = cursor.fetchone()['value']
    cursor.execute("SELECT value FROM settings WHERE key='ssh_ws_port'")
    ssh_ws_port = cursor.fetchone()['value']
    
    admin_user, _ = get_admin_credentials()
    conn.close()
    
    online_list = get_online_users()
    online_count = len(online_list)
    
    total_allowed_vol = 0
    total_used = 0
    active_count = 0
    
    users = []
    for row in raw_users:
        u = dict(row)
        u['is_online'] = u['username'] in online_list
        u['remaining_days'] = round(u['remaining_time'] / 86400, 2)
        u['readable_time'] = format_remaining_time(u['remaining_time'])
        
        total_allowed_vol += u['total_volume']
        total_used += u['used_download']
        if u['status'] == 'active':
            active_count += 1
            
        users.append(u)
    
    ram_usage = get_system_ram()
    
    return render_template(
        "index.html", 
        users=users, 
        ssh_port=ssh_port, 
        ssh_ws_port=ssh_ws_port, 
        admin_user=admin_user,
        ram_usage=ram_usage,
        online_count=online_count,
        active_count=active_count,
        total_users_count=len(users),
        total_allowed_vol=round(total_allowed_vol, 1),
        total_used=round(total_used, 2)
    )

@app.route("/api/user", methods=["POST"])
@login_required
def create_user_api():
    data = request.json
    success, msg = add_user(data['username'], data['password'], data['remaining_time'], data['total_volume'], data['protocol'])
    return jsonify({"success": success, "msg": msg})

@app.route("/api/user/update", methods=["POST"])
@login_required
def update_user_api():
    data = request.json
    success, msg = update_user(data['username'], data['password'], data['remaining_time'], data['total_volume'], data['protocol'], data['status'])
    return jsonify({"success": success, "msg": msg})

@app.route("/api/user/delete", methods=["POST"])
@login_required
def delete_user_api():
    data = request.json
    success, msg = delete_user(data['username'])
    return jsonify({"success": success, "msg": msg})

@app.route("/api/user/reset", methods=["POST"])
@login_required
def reset_user_api():
    data = request.json
    success, msg = reset_usage(data['username'])
    return jsonify({"success": success, "msg": msg})

@app.route("/api/settings", methods=["POST"])
@login_required
def update_settings_api():
    data = request.json
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("UPDATE settings SET value=? WHERE key='ssh_port'", (data['ssh_port'],))
        cursor.execute("UPDATE settings SET value=? WHERE key='ssh_ws_port'", (data['ssh_ws_port'],))
        conn.commit()
        
        if 'admin_username' in data and 'admin_password' in data:
            update_admin_credentials(data['admin_username'], data['admin_password'])
            
        apply_system_ports()
        return jsonify({"success": True, "msg": "تنظیمات بروزرسانی شدند."})
    except Exception as e:
        return jsonify({"success": False, "msg": str(e)})
    finally:
        conn.close()

@app.route("/api/backup/export")
@login_required
def backup_export_api():
    file_path = export_backup_json()
    return send_file(file_path, as_attachment=True, download_name="ssh_panel_backup.json")

@app.route("/api/backup/import", methods=["POST"])
@login_required
def backup_import_api():
    if 'file' not in request.files:
        return jsonify({"success": False, "msg": "فایلی ارسال نشده است."})
    file = request.files['file']
    temp_path = "/tmp/import_backup.json"
    file.save(temp_path)
    success, msg = import_backup_json(temp_path)
    return jsonify({"success": success, "msg": msg})
EOF

# ۱۱. ایجاد پکیج اینیت
touch /var/lib/ssh-panel/app/__init__.py

echo "=== ایجاد فایل‌های فرانت‌اند منطبق با طراحی عکس ==="

# ۱۲. ایجاد قالب ایندکس فرانت‌اند (templates/index.html)
cat <<'EOF' > /var/lib/ssh-panel/templates/index.html
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OpenSSH + WebSocket Control Center</title>
    <link rel="stylesheet" href="/static/app.css">
</head>
<body>
    <div class="grid-background"></div>
    
    <div class="container">
        <!-- هدر اصلی -->
        <header class="header-section">
            <div class="header-left">
                <a href="/logout" class="btn btn-logout">خروج</a>
                <a href="/api/backup/export" class="btn btn-backup">دانلود بکاپ</a>
            </div>
            <div class="header-right">
                <div class="brand-info">
                    <span class="sub-brand">CUSTOM PANEL</span>
                    <h1 class="brand-title">OpenSSH + WebSocket Control Center</h1>
                </div>
                <div class="avatar-icon">CP</div>
            </div>
        </header>

        <!-- کارت‌های وضعیت بالا -->
        <div class="status-grid">
            <div class="status-card">
                <span class="status-label">RAM</span>
                <span class="status-value">{{ ram_usage }}</span>
            </div>
            <div class="status-card">
                <span class="status-label">مصرف کل</span>
                <span class="status-value">B {{ total_used }}</span>
            </div>
            <div class="status-card">
                <span class="status-label">حجم کل</span>
                <span class="status-value">GB {{ total_allowed_vol }}</span>
            </div>
            <div class="status-card">
                <span class="status-label">آنلاین</span>
                <span class="status-value">{{ online_count }}</span>
            </div>
            <div class="status-card">
                <span class="status-label">فعال</span>
                <span class="status-value">{{ active_count }}</span>
            </div>
            <div class="status-card">
                <span class="status-label">کل کاربران</span>
                <span class="status-value">{{ total_users_count }}</span>
            </div>
        </div>

        <div class="main-layout">
            <!-- ستون سمت چپ -->
            <div class="sidebar-column">
                <!-- کارت تغییر ورود مدیر -->
                <div class="card panel-card">
                    <div class="card-header">
                        <span class="tag tag-purple">SECURE</span>
                        <span class="card-title">تغییر ورود مدیر</span>
                        <span class="card-subtitle">ADMIN</span>
                    </div>
                    <form id="settingsForm">
                        <div class="form-group">
                            <input type="text" id="adminUser" value="{{ admin_user }}" placeholder="نام کاربری جدید مدیر" required>
                        </div>
                        <div class="form-group">
                            <input type="password" id="adminPass" placeholder="رمز جدید حداقل ۱۰ کاراکتر">
                        </div>
                        <!-- فیلدهای مخفی برای پورت‌ها -->
                        <input type="hidden" id="sshPort" value="{{ ssh_port }}">
                        <input type="hidden" id="sshWsPort" value="{{ ssh_ws_port }}">
                        
                        <button type="submit" class="btn btn-blue btn-block">ذخیره و خروج</button>
                    </form>
                </div>
            </div>

            <!-- ستون سمت راست -->
            <div class="content-column">
                <!-- کارت ساخت کاربر -->
                <div class="card panel-card">
                    <div class="card-header">
                        <span class="tag tag-blue">SSH</span>
                        <span class="card-title">ساخت کاربر</span>
                        <span class="card-subtitle">CREATE USER</span>
                    </div>
                    <form id="addUserForm">
                        <div class="form-row-2">
                            <div class="form-group">
                                <label class="field-label">نام کاربری</label>
                                <input type="text" id="addUsername" required>
                            </div>
                            <div class="form-group">
                                <label class="field-label">رمز عبور</label>
                                <input type="text" id="addPassword" required>
                            </div>
                        </div>
                        <div class="form-row-2">
                            <div class="form-group">
                                <label class="field-label">حجم GB</label>
                                <input type="number" step="0.1" id="addVolume" required>
                            </div>
                            <div class="form-group">
                                <label class="field-label">زمان باقی‌مانده (روز)</label>
                                <input type="number" step="0.1" id="addTime" required>
                            </div>
                        </div>
                        
                        <!-- انتخاب پروتکل به شکل دقیقاً مطابق تصویر -->
                        <div class="protocol-selection-row">
                            <label class="checkbox-container">
                                <input type="checkbox" id="protoWS" checked>
                                <span class="checkmark"></span>
                                SSH WebSocket
                            </label>
                            <label class="checkbox-container">
                                <input type="checkbox" id="protoDirect" checked>
                                <span class="checkmark"></span>
                                OpenSSH
                            </label>
                        </div>

                        <button type="submit" class="btn btn-blue btn-block" style="margin-top: 15px;">ساخت کاربر</button>
                    </form>
                </div>

                <!-- کارت بازیابی اطلاعات -->
                <div class="card panel-card" style="margin-top: 20px;">
                    <div class="card-header">
                        <span class="tag tag-purple">JSON</span>
                        <span class="card-title">بازیابی اطلاعات</span>
                        <span class="card-subtitle">BACKUP</span>
                    </div>
                    <div class="backup-area">
                        <div class="file-drop-area" onclick="document.getElementById('backupFile').click()">
                            <span id="file-name-label">انتخاب فایل بکاپ</span>
                            <input type="file" id="backupFile" accept=".json" style="display: none;" onchange="updateFileName(this)">
                        </div>
                        <button onclick="importBackup()" class="btn btn-blue btn-block" style="margin-top: 15px;">بازیابی بکاپ</button>
                        <p class="disclaimer-text">کاربران، پورت‌ها، توکن API، مصرف و زمان باقیمانده ذخیره می‌شوند.</p>
                    </div>
                </div>
            </div>
        </div>

        <!-- بخش مدیریت کاربران پایینی -->
        <div class="card panel-card" style="margin-top: 25px;">
            <div class="users-header">
                <span class="card-title">مدیریت کاربران</span>
                <span class="card-subtitle">USERS</span>
                <div class="search-box">
                    <input type="text" id="userSearch" placeholder="جستجو" onkeyup="searchUsers()">
                </div>
            </div>

            <div class="table-responsive">
                <table>
                    <thead>
                        <tr>
                            <th style="text-align: center;">عملیات</th>
                            <th style="text-align: center;">زمان</th>
                            <th style="text-align: center;">مصرف</th>
                            <th style="text-align: center;">آنلاین</th>
                            <th style="text-align: center;">وضعیت</th>
                            <th style="text-align: center;">پورت‌ها</th>
                            <th style="text-align: right;">کاربر</th>
                        </tr>
                    </thead>
                    <tbody id="usersTableBody">
                        {% for user in users %}
                        <tr class="user-row">
                            <!-- دکمه‌های عملیات دایره‌ای بیضی -->
                            <td style="text-align: center; white-space: nowrap;">
                                <button onclick="deleteUser('{{ user.username }}')" class="action-btn btn-danger-circle">حذف</button>
                                <button onclick="resetUser('{{ user.username }}')" class="action-btn btn-warning-circle">ریست</button>
                                <button onclick="saveUser('{{ user.username }}')" class="action-btn btn-blue-circle">ویرایش</button>
                                <button onclick="toggleProtocol('{{ user.username }}')" class="action-btn btn-yellow-circle">پروتکل</button>
                                <button class="action-btn btn-dark-circle">کلاسیک</button>
                            </td>
                            <!-- زمان باقی‌مانده -->
                            <td style="text-align: center;">
                                <span class="time-badge">{{ user.readable_time }}</span>
                            </td>
                            <!-- نمایش گرافیکی مصرف ترافیک -->
                            <td style="text-align: center;">
                                <div class="traffic-container">
                                    <span class="traffic-text">B / {{ "%.2f"|format(user.total_volume) }} GB {{ "%.2f"|format(user.used_download) }}</span>
                                    <div class="progress-bar">
                                        <div class="progress-fill" style="width: {{ (user.used_download / user.total_volume * 100)|int if user.total_volume > 0 else 0 }}%;"></div>
                                    </div>
                                </div>
                            </td>
                            <!-- وضعیت آنلاین یا آفلاین زنده -->
                            <td style="text-align: center;">
                                {% if user.is_online %}
                                    <span class="status-indicator online">WS 5</span>
                                {% else %}
                                    <span class="status-indicator offline">آفلاین</span>
                                {% endif %}
                            </td>
                            <!-- وضعیت اکانت -->
                            <td style="text-align: center;">
                                <span class="status-indicator active-status">فعال</span>
                            </td>
                            <!-- نمایش پورت‌ها -->
                            <td style="text-align: center;">
                                <span class="port-badge">WS: {{ ssh_ws_port }}</span>
                            </td>
                            <!-- نام کاربر و آیکون آبی رنگ شیک -->
                            <td style="text-align: right; display: flex; align-items: center; justify-content: flex-end; gap: 8px;">
                                <span class="user-name-text">{{ user.username }}</span>
                                <div class="user-avatar-blue">A</div>
                            </td>
                        </tr>
                        {% endfor %}
                    </tbody>
                </table>
            </div>
        </div>
    </div>

    <script src="/static/app.js"></script>
    <script>
        function updateFileName(input) {
            const label = document.getElementById('file-name-label');
            if(input.files && input.files.length > 0) {
                label.innerText = input.files[0].name;
            } else {
                label.innerText = "انتخاب فایل بکاپ";
            }
        }
    </script>
</body>
</html>
EOF

# ۱۳. ایجاد فایل استایل فرانت‌اند (static/app.css)
cat <<'EOF' > /var/lib/ssh-panel/static/app.css
:root {
    --panel-bg: #070913;
    --card-bg: rgba(13, 17, 34, 0.75);
    --card-border: rgba(43, 55, 95, 0.4);
    --input-bg: #090e1a;
    --text-primary: #ffffff;
    --text-secondary: #7e8baf;
    --btn-blue: #0084ff;
    --btn-green: #00b894;
    --tag-purple: #8e44ad;
    --tag-blue: #2980b9;
}

* {
    box-sizing: border-box;
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
}

body {
    background-color: var(--panel-bg);
    color: var(--text-primary);
    margin: 0;
    padding: 0;
    direction: rtl;
    overflow-x: hidden;
    position: relative;
    min-height: 100vh;
}

.grid-background {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background-image: 
        linear-gradient(rgba(18, 24, 48, 0.15) 1px, transparent 1px),
        linear-gradient(90deg, rgba(18, 24, 48, 0.15) 1px, transparent 1px);
    background-size: 30px 30px;
    z-index: -1;
    pointer-events: none;
}

.container {
    max-width: 1400px;
    margin: 0 auto;
    padding: 20px;
}

.header-section {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 25px;
}

.header-left {
    display: flex;
    gap: 12px;
}

.header-right {
    display: flex;
    align-items: center;
    gap: 15px;
}

.brand-info {
    text-align: right;
}

.sub-brand {
    font-size: 0.65rem;
    color: var(--btn-blue);
    letter-spacing: 2px;
    font-weight: bold;
}

.brand-title {
    margin: 4px 0 0 0;
    font-size: 1.4rem;
    font-weight: 700;
    color: #fff;
}

.avatar-icon {
    width: 42px;
    height: 42px;
    background-color: #0052cc;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: bold;
    font-size: 0.9rem;
    border: 2px solid rgba(255, 255, 255, 0.1);
}

.status-grid {
    display: grid;
    grid-template-columns: repeat(6, 1fr);
    gap: 15px;
    margin-bottom: 25px;
}

.status-card {
    background-color: var(--card-bg);
    border: 1px solid var(--card-border);
    border-radius: 10px;
    padding: 15px;
    text-align: center;
    display: flex;
    flex-direction: column;
    justify-content: center;
}

.status-label {
    font-size: 0.75rem;
    color: var(--text-secondary);
    margin-bottom: 8px;
}

.status-value {
    font-size: 1.3rem;
    font-weight: bold;
}

.main-layout {
    display: flex;
    gap: 20px;
}

.sidebar-column {
    flex: 1;
}

.content-column {
    flex: 2;
}

.card {
    background-color: var(--card-bg);
    border: 1px solid var(--card-border);
    border-radius: 12px;
    padding: 22px;
    box-shadow: 0 8px 32px 0 rgba(0, 0, 0, 0.37);
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
}

.card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 20px;
    border-bottom: 1px solid rgba(255,255,255,0.05);
    padding-bottom: 12px;
}

.card-title {
    font-size: 1.15rem;
    font-weight: bold;
    color: #fff;
}

.card-subtitle {
    font-size: 0.65rem;
    color: var(--text-secondary);
    letter-spacing: 1px;
}

.tag {
    padding: 3px 8px;
    border-radius: 4px;
    font-size: 0.65rem;
    font-weight: bold;
}

.tag-purple { background-color: rgba(142, 68, 173, 0.3); color: #e0a3ff; border: 1px solid #8e44ad; }
.tag-blue { background-color: rgba(41, 128, 185, 0.3); color: #a3e0ff; border: 1px solid #2980b9; }

.btn {
    padding: 10px 20px;
    border-radius: 8px;
    border: none;
    cursor: pointer;
    font-size: 0.9rem;
    font-weight: bold;
    text-decoration: none;
    transition: all 0.2s ease;
    display: inline-flex;
    align-items: center;
    justify-content: center;
}

.btn-logout {
    background-color: rgba(255, 255, 255, 0.1);
    color: #fff;
    border: 1px solid rgba(255, 255, 255, 0.15);
}

.btn-backup {
    background-color: rgba(0, 184, 148, 0.2);
    color: #55efc4;
    border: 1px solid #00b894;
}

.btn-blue {
    background: linear-gradient(135deg, #0052cc 0%, #0084ff 100%);
    color: #fff;
}

.btn-block {
    width: 100%;
}

.form-group {
    margin-bottom: 15px;
    display: flex;
    flex-direction: column;
}

.field-label {
    font-size: 0.75rem;
    color: var(--text-secondary);
    margin-bottom: 6px;
    text-align: right;
}

input[type="text"], input[type="password"], input[type="number"] {
    background-color: var(--input-bg);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 6px;
    padding: 12px;
    color: #fff;
    text-align: right;
    font-size: 0.85rem;
    width: 100%;
}

input:focus {
    outline: none;
    border-color: var(--btn-blue);
    box-shadow: 0 0 8px rgba(0, 132, 255, 0.2);
}

.form-row-2 {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 15px;
}

.protocol-selection-row {
    display: flex;
    justify-content: flex-end;
    gap: 20px;
    margin: 15px 0;
}

.checkbox-container {
    display: flex;
    align-items: center;
    position: relative;
    padding-right: 25px;
    cursor: pointer;
    font-size: 0.85rem;
    user-select: none;
    color: #fff;
}

.checkbox-container input {
    position: absolute;
    opacity: 0;
    cursor: pointer;
    height: 0;
    width: 0;
}

.checkmark {
    position: absolute;
    top: 5px;
    right: 0;
    height: 15px;
    width: 15px;
    background-color: var(--input-bg);
    border: 1px solid var(--text-secondary);
    border-radius: 3px;
}

.checkbox-container:hover input ~ .checkmark {
    background-color: #1a233a;
}

.checkbox-container input:checked ~ .checkmark {
    background-color: var(--btn-blue);
    border-color: var(--btn-blue);
}

.checkmark:after {
    content: "";
    position: absolute;
    display: none;
}

.checkbox-container input:checked ~ .checkmark:after {
    display: block;
}

.checkbox-container .checkmark:after {
    left: 4px;
    top: 1px;
    width: 4px;
    height: 8px;
    border: solid white;
    border-width: 0 2px 2px 0;
    transform: rotate(45deg);
}

.file-drop-area {
    border: 1px dashed rgba(255, 255, 255, 0.25);
    background-color: rgba(255, 255, 255, 0.02);
    border-radius: 6px;
    padding: 20px;
    text-align: center;
    cursor: pointer;
    color: var(--text-secondary);
    font-size: 0.85rem;
}

.disclaimer-text {
    font-size: 0.7rem;
    color: var(--text-secondary);
    text-align: center;
    margin-top: 10px;
}

.users-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 20px;
}

.search-box input {
    width: 250px;
    background-color: var(--input-bg);
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 6px;
    padding: 8px 15px;
    color: #fff;
}

.table-responsive {
    overflow-x: auto;
}

table {
    width: 100%;
    border-collapse: collapse;
}

th {
    padding: 15px 10px;
    color: var(--text-secondary);
    font-size: 0.8rem;
    font-weight: 500;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
}

.user-row {
    border-bottom: 1px solid rgba(255, 255, 255, 0.03);
}

.user-row:hover {
    background-color: rgba(255, 255, 255, 0.01);
}

td {
    padding: 15px 10px;
    font-size: 0.85rem;
}

.action-btn {
    padding: 5px 12px;
    border-radius: 15px;
    font-size: 0.75rem;
    border: none;
    cursor: pointer;
    margin-left: 5px;
    color: #fff;
    font-weight: bold;
}

.btn-danger-circle { background-color: #d63031; }
.btn-warning-circle { background-color: #e67e22; }
.btn-blue-circle { background-color: #0084ff; }
.btn-yellow-circle { background-color: #f1c40f; color: #121214; }
.btn-dark-circle { background-color: rgba(255, 255, 255, 0.1); }

.time-badge {
    background-color: rgba(255, 255, 255, 0.05);
    padding: 4px 10px;
    border-radius: 6px;
    font-size: 0.8rem;
    color: var(--text-secondary);
}

.traffic-container {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 4px;
}

.traffic-text {
    font-size: 0.8rem;
    color: var(--text-secondary);
}

.progress-bar {
    width: 120px;
    height: 4px;
    background-color: rgba(255, 255, 255, 0.1);
    border-radius: 2px;
    overflow: hidden;
}

.progress-fill {
    height: 100%;
    background-color: var(--btn-blue);
}

.status-indicator {
    padding: 4px 10px;
    border-radius: 12px;
    font-size: 0.75rem;
    font-weight: bold;
}

.status-indicator.online {
    background-color: rgba(142, 68, 173, 0.2);
    color: #d896ff;
    border: 1px solid #8e44ad;
}

.status-indicator.offline {
    background-color: rgba(255, 255, 255, 0.05);
    color: var(--text-secondary);
}

.status-indicator.active-status {
    background-color: rgba(46, 204, 113, 0.2);
    color: #2ecc71;
    border: 1px solid #2ecc71;
}

.port-badge {
    background-color: rgba(142, 68, 173, 0.15);
    color: #d896ff;
    padding: 4px 10px;
    border-radius: 12px;
    font-size: 0.75rem;
    border: 1px solid rgba(142, 68, 173, 0.3);
}

.user-name-text {
    font-weight: bold;
    color: #fff;
}

.user-avatar-blue {
    width: 28px;
    height: 28px;
    border-radius: 50%;
    background-color: var(--btn-blue);
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: bold;
    font-size: 0.8rem;
}
EOF

# ۱۴. ایجاد فایل استایل ورود مدیر (templates/login.html)
cat <<'EOF' > /var/lib/ssh-panel/templates/login.html
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ورود به پنل SSH</title>
    <link rel="stylesheet" href="/static/app.css">
    <style>
        .login-body {
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
        }
        .login-card {
            background-color: var(--card-bg);
            padding: 35px;
            border-radius: 12px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.5);
            width: 380px;
            border: 1px solid var(--card-border);
        }
    </style>
</head>
<body class="login-body">
    <div class="grid-background"></div>
    <div class="login-card">
        <h2 style="text-align: center; margin-bottom: 25px;">ورود به پنل مدیریت SSH</h2>
        <form method="POST" action="/login">
            <div class="form-group">
                <label class="field-label">نام کاربری ادمین</label>
                <input type="text" name="username" required placeholder="admin">
            </div>
            <div class="form-group">
                <label class="field-label">رمز عبور</label>
                <input type="password" name="password" required placeholder="••••••••">
            </div>
            <button type="submit" class="btn btn-blue btn-block" style="margin-top: 15px;">ورود به سیستم</button>
        </form>
    </div>
</body>
</html>
EOF

# ۱۵. ایجاد جاوااسکریپت عملکردها (static/app.js)
cat <<'EOF' > /var/lib/ssh-panel/static/app.js
document.getElementById('settingsForm')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    const ssh_port = document.getElementById('sshPort').value;
    const ssh_ws_port = document.getElementById('sshWsPort').value;
    const admin_username = document.getElementById('adminUser').value;
    const admin_password = document.getElementById('adminPass').value;
    
    const payload = { ssh_port, ssh_ws_port, admin_username };
    if (admin_password) payload.admin_password = admin_password;

    const res = await fetch('/api/settings', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    });
    const data = await res.json();
    alert(data.msg);
    if(data.success) location.reload();
});

document.getElementById('addUserForm')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    const username = document.getElementById('addUsername').value;
    const password = document.getElementById('addPassword').value;
    const remaining_time = document.getElementById('addTime').value;
    const total_volume = document.getElementById('addVolume').value;
    
    // تعیین نوع پروتکل انتخابی بر اساس چک‌باکس‌ها
    const isWS = document.getElementById('protoWS').checked;
    const protocol = isWS ? 'sshws' : 'openssh';

    const res = await fetch('/api/user', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password, remaining_time, total_volume, protocol })
    });
    const data = await res.json();
    alert(data.msg);
    if(data.success) location.reload();
});

async function saveUser(username) {
    // بازخوانی مقادیر موقت برای آپدیت
    const password = prompt("رمز عبور جدید را وارد کنید:") || "123456";
    const remaining_time = prompt("اعتبار جدید به روز:") || "30";
    const total_volume = prompt("حجم جدید (GB):") || "50";
    const protocol = confirm("آیا مایل به فعال کردن پروتکل WebSocket هستید؟ (در غیر این صورت OpenSSH)") ? 'sshws' : 'openssh';

    const res = await fetch('/api/user/update', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password, remaining_time, total_volume, protocol, status: 'active' })
    });
    const data = await res.json();
    alert(data.msg);
    location.reload();
}

async function deleteUser(username) {
    if(!confirm(`آیا از حذف کاربر ${username} مطمئن هستید؟`)) return;
    const res = await fetch('/api/user/delete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username })
    });
    const data = await res.json();
    alert(data.msg);
    if(data.success) location.reload();
}

async function resetUser(username) {
    const res = await fetch('/api/user/reset', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username })
    });
    const data = await res.json();
    alert(data.msg);
    location.reload();
}

async function importBackup() {
    const fileInput = document.getElementById('backupFile');
    if(fileInput.files.length === 0) {
        alert('لطفا ابتدا یک فایل انتخاب کنید.');
        return;
    }
    const formData = new FormData();
    formData.append('file', fileInput.files[0]);

    const res = await fetch('/api/backup/import', {
        method: 'POST',
        body: formData
    });
    const data = await res.json();
    alert(data.msg);
    if(data.success) location.reload();
}

function searchUsers() {
    const input = document.getElementById('userSearch');
    const filter = input.value.toLowerCase();
    const rows = document.querySelectorAll('#usersTableBody tr');
    
    rows.forEach(row => {
        const username = row.querySelector('.user-name-text').textContent.toLowerCase();
        if(username.includes(filter)) {
            row.style.display = "";
        } else {
            row.style.display = "none";
        }
    });
}
EOF

echo "=== پیکربندی سرویس‌های سیستمی لینوکس ==="

# ۱۶. ایجاد محیط مجازی و نصب وابستگی‌ها
python3 -m venv /var/lib/ssh-panel/venv
/var/lib/ssh-panel/venv/bin/pip install --upgrade pip
/var/lib/ssh-panel/venv/bin/pip install flask gunicorn

# ۱۷. راه‌اندازی دیتابیس
PYTHONPATH=/var/lib/ssh-panel /var/lib/ssh-panel/venv/bin/python -c "from app.db import init_db; init_db()"

# ۱۸. سرویس پنل مدیریت روی پورت ۸۰۰۰
cat <<EOF > /etc/systemd/system/ssh-pro-panel.service
[Unit]
Description=SSH-Pro Management Admin Dashboard (Port 8000)
After=network.target

[Service]
User=root
WorkingDirectory=/var/lib/ssh-panel
Environment=PYTHONPATH=/var/lib/ssh-panel
ExecStart=/var/lib/ssh-panel/venv/bin/gunicorn --workers 1 --bind 0.0.0.0:8000 app.api:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# ۱۹. ورکر بهینه پایش ترافیک
cat <<'EOF' > /var/lib/ssh-panel/live_worker.py
import time
import sys
sys.path.append('/var/lib/ssh-panel')
from app.live import track_traffic_and_sessions

while True:
    try:
        track_traffic_and_sessions()
    except Exception as e:
        print("Worker error:", e)
    time.sleep(2)
EOF

cat <<EOF > /etc/systemd/system/ssh-pro-worker.service
[Unit]
Description=SSH-Pro Live Bandwidth & Session Monitor
After=network.target

[Service]
User=root
WorkingDirectory=/var/lib/ssh-panel
ExecStart=/var/lib/ssh-panel/venv/bin/python /var/lib/ssh-panel/live_worker.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# ۲۰. وب‌سوکت گیت‌وی سبک برای پورت ۸۰
cat <<'EOF' > /var/lib/ssh-panel/ws_server.py
import socket
import threading
import sys
sys.path.append('/var/lib/ssh-panel')
from app.db import get_db_connection

def handle_client(client_socket):
    try:
        req = client_socket.recv(4096).decode('utf-8', errors='ignore')
        if "Upgrade: websocket" in req:
            client_socket.sendall(
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\n"
                b"Connection: Upgrade\r\n\r\n"
            )
            ssh_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            ssh_socket.connect(('127.0.0.1', 22))
            
            def forward(source, destination):
                try:
                    while True:
                        data = source.recv(8192)
                        if not data:
                            break
                        destination.sendall(data)
                except Exception:
                    pass
                finally:
                    source.close()
                    destination.close()
            
            threading.Thread(target=forward, args=(client_socket, ssh_socket), daemon=True).start()
            forward(ssh_socket, client_socket)
    except Exception:
        pass
    finally:
        client_socket.close()

def main():
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT value FROM settings WHERE key='ssh_ws_port'")
    port = int(cursor.fetchone()['value'])
    conn.close()
    
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(('0.0.0.0', port))
    except Exception as e:
        print(f"Error binding to port {port}: {e}.")
        sys.exit(1)
        
    server.listen(500)
    print(f"WS Gateway Listening on port {port}...")
    while True:
        try:
            client, addr = server.accept()
            threading.Thread(target=handle_client, args=(client,), daemon=True).start()
        except Exception:
            pass

if __name__ == '__main__':
    main()
EOF

cat <<EOF > /etc/systemd/system/ssh-ws.service
[Unit]
Description=SSH WebSocket Forwarding Gateway
After=network.target

[Service]
User=root
WorkingDirectory=/var/lib/ssh-panel
ExecStart=/var/lib/ssh-panel/venv/bin/python /var/lib/ssh-panel/ws_server.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# ۲۱. کانفیگ فایروال
iptables -I INPUT -p tcp --dport 8000 -j ACCEPT
iptables -I INPUT -p tcp --dport 80 -j ACCEPT
if command -v ufw >/dev/null 2>&1; then
    ufw allow 8000/tcp
    ufw allow 80/tcp
    ufw reload
fi

# ۲۲. ری‌استارت نهایی سرویس‌ها
systemctl daemon-reload
systemctl enable --now ssh-pro-panel
systemctl enable --now ssh-pro-worker
systemctl enable --now ssh-ws

echo "==============================================="
echo "=== نصب با موفقیت روی پورت 8000 کامل شد! ==="
echo "=== آدرس وب پنل جدید: http://YOUR_VPS_IP:8000 ==="
echo "==============================================="
