#!/bin/bash
# Clean Installation & Setup Script for SSH-Pro Custom Web Panel (Port 5000)
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

echo "=== ایجاد فایل‌های ساختاری پایتون (محیط بهینه WAL) ==="

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
        remaining_time INTEGER NOT NULL, -- ذخیره به ثانیه در دیتابیس برای پایش دقیق
        total_volume REAL NOT NULL,
        used_download REAL DEFAULT 0.0,
        used_upload REAL DEFAULT 0.0,
        status TEXT DEFAULT 'active',
        protocol TEXT DEFAULT 'openssh', -- مقدار جدید: openssh یا sshws
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

# ۶. ایجاد بخش اعمال پورت‌های سیستم (app/protocols.py)
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
    # تبدیل روز به ثانیه برای محاسبات دقیق بک‌اند
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

# ۹. پایش زنده و مصرف ترافیک بهینه شده برای تعداد کاربر بالا (app/live.py)
cat <<'EOF' > /var/lib/ssh-panel/app/live.py
import subprocess
from app.db import get_db_connection

def get_online_users():
    online_list = set() # استفاده از Set برای بررسی سریع‌تر در تعداد کاربر بالا
    try:
        # دریافت بهینه لیست پروسس‌های اس‌اس‌اچ با فرمت مناسب
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
    
    # مانیتور کردن فقط کاربران فعال برای کاهش سربار دیتابیس
    cursor.execute("SELECT id, username, remaining_time, total_volume, used_download, status FROM users WHERE status='active'")
    active_users = cursor.fetchall()
    online_users = set(get_online_users())
    
    for u in active_users:
        u_id = u['id']
        username = u['username']
        rem_time = u['remaining_time']
        used_dl = u['used_download']
        total_vol = u['total_volume']
        
        # اگر کاربر آنلاین است، ۲ ثانیه از اعتبار او کسر کن
        if username in online_users:
            new_time = max(0, rem_time - 2)
            cursor.execute("UPDATE users SET remaining_time=? WHERE id=?", (new_time, u_id))
            rem_time = new_time
            
        # چک کردن انقضا به دلیل اتمام زمان یا ترافیک
        if rem_time <= 0 or used_dl >= total_vol:
            cursor.execute("UPDATE users SET status='expired' WHERE id=?", (u_id,))
            subprocess.run(["usermod", "-L", username], capture_output=True)
            subprocess.run(f"pkill -u {username}", shell=True, capture_output=True)
            
    conn.commit()
    conn.close()
EOF

# ۱۰. هسته اصلی وب‌سایت ادمین (app/api.py)
cat <<'EOF' > /var/lib/ssh-panel/app/api.py
from flask import Flask, render_template, request, jsonify, session, redirect, url_for, flash, send_file
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
    
    users = []
    for row in raw_users:
        u = dict(row)
        u['is_online'] = u['username'] in online_list
        u['remaining_days'] = round(u['remaining_time'] / 86400, 2)
        u['readable_time'] = format_remaining_time(u['remaining_time'])
        users.append(u)
    
    return render_template("index.html", users=users, ssh_port=ssh_port, ssh_ws_port=ssh_ws_port, admin_user=admin_user)

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

# ۱۱. ایجاد فایل خالی برای ساختار پایتون
touch /var/lib/ssh-panel/app/__init__.py

echo "=== طراحی بخش ظاهری (Front-End) مدرن و دارک ==="

# ۱۲. طراحی صفحه لاگین تم تیره (templates/login.html)
cat <<'EOF' > /var/lib/ssh-panel/templates/login.html
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ورود به پنل SSH</title>
    <link rel="stylesheet" href="/static/app.css">
</head>
<body class="login-body">
    <div class="login-card">
        <h2>ورود به پنل مدیریت SSH</h2>
        <form method="POST" action="/login">
            <div class="form-group">
                <label>نام کاربری ادمین</label>
                <input type="text" name="username" required placeholder="admin">
            </div>
            <div class="form-group">
                <label>رمز عبور</label>
                <input type="password" name="password" required placeholder="••••••••">
            </div>
            <button type="submit" class="btn btn-primary btn-block">ورود به سیستم</button>
        </form>
    </div>
</body>
</html>
EOF

# ۱۳. طراحی داشبورد مدیریت با قابلیت پروتکل و زمان روزانه (templates/index.html)
cat <<'EOF' > /var/lib/ssh-panel/templates/index.html
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>مدیریت کاربران SSH-Pro</title>
    <link rel="stylesheet" href="/static/app.css">
</head>
<body>
    <header class="navbar">
        <div class="logo">پنل مدیریت SSH-Pro (OpenSSH & WS)</div>
        <div class="nav-actions">
            <a href="/logout" class="btn btn-danger">خروج</a>
        </div>
    </header>

    <div class="container">
        <div class="row">
            <div class="col card">
                <h3>تنظیمات سیستم و پورت‌ها</h3>
                <form id="settingsForm">
                    <div class="form-row" style="display: flex; gap: 10px; margin-bottom: 10px;">
                        <div class="form-group" style="flex: 1;">
                            <label>پورت OpenSSH</label>
                            <input type="number" id="sshPort" value="{{ ssh_port }}" required>
                        </div>
                        <div class="form-group" style="flex: 1;">
                            <label>پورت SSH WebSocket</label>
                            <input type="number" id="sshWsPort" value="{{ ssh_ws_port }}" required>
                        </div>
                    </div>
                    <div class="form-row" style="display: flex; gap: 10px; margin-bottom: 10px;">
                        <div class="form-group" style="flex: 1;">
                            <label>نام کاربری جدید مدیر</label>
                            <input type="text" id="adminUser" value="{{ admin_user }}" required>
                        </div>
                        <div class="form-group" style="flex: 1;">
                            <label>رمز عبور جدید مدیر</label>
                            <input type="password" id="adminPass" placeholder="بدون تغییر رها کنید">
                        </div>
                    </div>
                    <button type="submit" class="btn btn-success">ثبت و بروزرسانی پورت‌ها</button>
                </form>
            </div>

            <div class="col card">
                <h3>پشتیبان‌گیری هوشمند (JSON)</h3>
                <p class="text-muted" style="font-size: 0.85rem; color: #a0a0b0;">انتقال آسان کاربران به سرور جدید بدون از دست رفتن اطلاعات.</p>
                <div class="backup-actions">
                    <a href="/api/backup/export" class="btn btn-primary" style="margin-bottom: 15px;">دانلود فایل پشتیبان</a>
                    <div style="border-top: 1px solid #2e2e36; margin-top: 10px; padding-top: 10px;">
                        <label>انتخاب فایل بکاپ:</label>
                        <input type="file" id="backupFile" accept=".json" style="margin-bottom: 10px;">
                        <button onclick="importBackup()" class="btn btn-warning" style="width: 100%;">آپلود و بازیابی</button>
                    </div>
                </div>
            </div>
        </div>

        <div class="card" style="margin-top: 20px;">
            <h3>ایجاد کاربر جدید</h3>
            <form id="addUserForm" style="display: flex; gap: 10px; flex-wrap: wrap; align-items: flex-end;">
                <div style="flex: 1; min-width: 120px;">
                    <label>نام کاربری</label>
                    <input type="text" id="addUsername" placeholder="Username" required style="width: 100%;">
                </div>
                <div style="flex: 1; min-width: 120px;">
                    <label>رمز عبور</label>
                    <input type="text" id="addPassword" placeholder="Password" required style="width: 100%;">
                </div>
                <div style="flex: 1; min-width: 120px;">
                    <label>مدت اعتبار (روز)</label>
                    <input type="number" step="0.1" id="addTime" placeholder="مثال: 30" required style="width: 100%;">
                </div>
                <div style="flex: 1; min-width: 120px;">
                    <label>ترافیک مجاز (GB)</label>
                    <input type="number" step="0.1" id="addVolume" placeholder="مثال: 50" required style="width: 100%;">
                </div>
                <div style="flex: 1; min-width: 150px;">
                    <label>نوع پروتکل اتصال</label>
                    <select id="addProtocol" style="width: 100%;">
                        <option value="openssh">OpenSSH معمولی</option>
                        <option value="sshws">SSH WebSocket (WS)</option>
                    </select>
                </div>
                <button type="submit" class="btn btn-primary" style="height: 42px;">افزودن کاربر</button>
            </form>
        </div>

        <div class="card" style="margin-top: 20px;">
            <h3>لیست کاربران</h3>
            <div style="overflow-x: auto;">
                <table>
                    <thead>
                        <tr>
                            <th>وضعیت اتصال</th>
                            <th>نام کاربری</th>
                            <th>رمز عبور</th>
                            <th>پروتکل</th>
                            <th>اعتبار (روز)</th>
                            <th>زمان باقی‌مانده</th>
                            <th>حجم کل (GB)</th>
                            <th>مصرف دانلود (GB)</th>
                            <th>وضعیت سیستم</th>
                            <th>عملیات</th>
                        </tr>
                    </thead>
                    <tbody id="usersTableBody">
                        {% for user in users %}
                        <tr>
                            <td>
                                {% if user.is_online %}
                                    <span class="badge badge-online">آنلاین</span>
                                {% else %}
                                    <span class="badge badge-offline">آفلاین</span>
                                {% endif %}
                            </td>
                            <td><strong>{{ user.username }}</strong></td>
                            <td><input type="text" value="{{ user.password }}" id="pwd-{{ user.username }}" style="width: 100px;"></td>
                            <td>
                                <select id="proto-{{ user.username }}" style="width: 110px;">
                                    <option value="openssh" {% if user.protocol == 'openssh' %}selected{% endif %}>OpenSSH</option>
                                    <option value="sshws" {% if user.protocol == 'sshws' %}selected{% endif %}>SSH WS</option>
                                </select>
                            </td>
                            <td><input type="number" step="0.1" value="{{ user.remaining_days }}" id="time-{{ user.username }}" style="width: 70px;"></td>
                            <td class="text-muted" style="font-size: 0.9rem;">{{ user.readable_time }}</td>
                            <td><input type="number" step="0.1" value="{{ user.total_volume }}" id="vol-{{ user.username }}" style="width: 70px;"></td>
                            <td><strong>{{ "%.2f"|format(user.used_download) }}</strong></td>
                            <td>
                                <select id="status-{{ user.username }}" style="width: 110px;">
                                    <option value="active" {% if user.status == 'active' %}selected{% endif %}>فعال</option>
                                    <option value="paused" {% if user.status == 'paused' %}selected{% endif %}>توقف موقت</option>
                                    <option value="expired" {% if user.status == 'expired' %}selected{% endif %}>منقضی</option>
                                </select>
                            </td>
                            <td>
                                <button onclick="saveUser('{{ user.username }}')" class="btn btn-success" style="padding: 5px 10px; font-size: 0.85rem;">ذخیره</button>
                                <button onclick="resetUser('{{ user.username }}')" class="btn btn-warning" style="padding: 5px 10px; font-size: 0.85rem;">ریست</button>
                                <button onclick="deleteUser('{{ user.username }}')" class="btn btn-danger" style="padding: 5px 10px; font-size: 0.85rem;">حذف</button>
                            </td>
                        </tr>
                        {% endfor %}
                    </tbody>
                </table>
            </div>
        </div>
    </div>
    
    <script src="/static/app.js"></script>
</body>
</html>
EOF

# ۱۴. فایل CSS تم تیره بهینه شده و نشان‌های وضعیت (static/app.css)
cat <<'EOF' > /var/lib/ssh-panel/static/app.css
:root {
    --bg-primary: #121214;
    --bg-secondary: #1a1a1e;
    --accent: #6c5ce7;
    --text-main: #e2e2e9;
    --text-muted: #a0a0b0;
    --success: #00b894;
    --warning: #f1c40f;
    --danger: #d63031;
}

* {
    box-sizing: border-box;
    font-family: system-ui, -apple-system, sans-serif;
}

body {
    background-color: var(--bg-primary);
    color: var(--text-main);
    margin: 0;
    padding: 0;
    direction: rtl;
}

.login-body {
    display: flex;
    justify-content: center;
    align-items: center;
    height: 100vh;
}

.login-card {
    background-color: var(--bg-secondary);
    padding: 30px;
    border-radius: 12px;
    box-shadow: 0 10px 30px rgba(0,0,0,0.5);
    width: 380px;
}

.navbar {
    background-color: var(--bg-secondary);
    padding: 15px 30px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-bottom: 1px solid #2e2e36;
}

.container {
    max-width: 1200px;
    margin: 30px auto;
    padding: 0 15px;
}

.card {
    background-color: var(--bg-secondary);
    border-radius: 10px;
    padding: 20px;
    margin-bottom: 20px;
}

.row {
    display: flex;
    gap: 20px;
}

.col {
    flex: 1;
}

h2, h3 {
    margin-top: 0;
    color: #fff;
}

.form-group {
    margin-bottom: 15px;
}

label {
    display: block;
    margin-bottom: 5px;
    font-size: 0.9rem;
    color: var(--text-muted);
}

input, select {
    width: 100%;
    padding: 10px;
    background-color: #242428;
    border: 1px solid #3e3e4a;
    border-radius: 6px;
    color: #fff;
}

.btn {
    padding: 10px 18px;
    border: none;
    border-radius: 6px;
    cursor: pointer;
    text-decoration: none;
    display: inline-block;
    text-align: center;
}

.btn-primary { background-color: var(--accent); color: #fff; }
.btn-success { background-color: var(--success); color: #fff; }
.btn-warning { background-color: var(--warning); color: #121214; }
.btn-danger { background-color: var(--danger); color: #fff; }
.btn-block { width: 100%; }

table {
    width: 100%;
    border-collapse: collapse;
    margin-top: 15px;
}

th, td {
    padding: 12px;
    text-align: right;
    border-bottom: 1px solid #2e2e36;
}

th {
    color: var(--text-muted);
}

.badge {
    padding: 4px 8px;
    border-radius: 4px;
    font-size: 0.8rem;
    font-weight: bold;
}
.badge-online {
    background-color: rgba(0, 184, 148, 0.15);
    color: var(--success);
    border: 1px solid var(--success);
}
.badge-offline {
    background-color: rgba(160, 160, 176, 0.1);
    color: var(--text-muted);
    border: 1px solid #3e3e4a;
}
EOF

# ۱۵. توسعه فایل عملگرهای ایجکس (static/app.js)
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
    const remaining_time = document.getElementById('addTime').value; // دریافت زمان به روز
    const total_volume = document.getElementById('addVolume').value;
    const protocol = document.getElementById('addProtocol').value;

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
    const password = document.getElementById(`pwd-${username}`).value;
    const remaining_time = document.getElementById(`time-${username}`).value; // دریافت زمان به روز
    const total_volume = document.getElementById(`vol-${username}`).value;
    const protocol = document.getElementById(`proto-${username}`).value;
    const status = document.getElementById(`status-${username}`).value;

    const res = await fetch('/api/user/update', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password, remaining_time, total_volume, protocol, status })
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
EOF

echo "=== پیکربندی محیط مجازی پایتون و سرویس‌های سیستمی ==="

# ۱۶. ایجاد محیط مجازی و نصب وابستگی‌ها
python3 -m venv /var/lib/ssh-panel/venv
/var/lib/ssh-panel/venv/bin/pip install --upgrade pip
/var/lib/ssh-panel/venv/bin/pip install flask gunicorn

# ۱۷. مقداردهی اولیه دیتابیس (اصلاح شده با PYTHONPATH جهت رفع دائمی خطا)
PYTHONPATH=/var/lib/ssh-panel /var/lib/ssh-panel/venv/bin/python -c "from app.db import init_db; init_db()"

# ۱۸. کانفیگ سرویس پنل مدیریت (Gunicorn روی پورت ۵۰۰۰)
cat <<EOF > /etc/systemd/system/ssh-pro-panel.service
[Unit]
Description=SSH-Pro Management Admin Dashboard (Port 5000)
After=network.target

[Service]
User=root
WorkingDirectory=/var/lib/ssh-panel
Environment=PYTHONPATH=/var/lib/ssh-panel
ExecStart=/var/lib/ssh-panel/venv/bin/gunicorn --workers 1 --bind 0.0.0.0:5000 app.api:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# ۱۹. کانفیگ ورکر سبک پایش و مانیتورینگ آنلاین
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

# ۲۰. ساخت سرور سبک وب‌سوکت پروکسی بدون تداخل برای پورت ۸۰ (ws_server.py)
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
                        data = source.recv(8192) # افزایش بافر برای پرفورمنس بالاتر
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
        print(f"Error binding to port {port}: {e}. Make sure Apache/Nginx is stopped.")
        sys.exit(1)
        
    server.listen(500) # افزایش بک‌لاگ به ۵۰۰ اتصال همزمان
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

# ۲۱. باز کردن پورت جدید ۵۰۰۰ و پورت ۸۰ روی فایروال لینوکس
iptables -I INPUT -p tcp --dport 5000 -j ACCEPT
iptables -I INPUT -p tcp --dport 80 -j ACCEPT
if command -v ufw >/dev/null 2>&1; then
    ufw allow 5000/tcp
    ufw allow 80/tcp
    ufw reload
fi

# ۲۲. راه‌اندازی کل سرویس‌ها روی لینوکس VPS
systemctl daemon-reload
systemctl enable --now ssh-pro-panel
systemctl enable --now ssh-pro-worker
systemctl enable --now ssh-ws

echo "==============================================="
echo "=== نصب تمیز کامل شد!                        ==="
echo "=== آدرس وب پنل جدید: http://YOUR_VPS_IP:5000 ==="
echo "==============================================="
