#!/bin/bash

# ۱. آزادسازی پورت ۵۰۰۰ و پاکسازی پروسس‌های قدیمی پایتون
sudo killall -9 python3 2>/dev/null
sudo fuser -k 5000/tcp 2>/dev/null
sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/lib/dpkg/lock 2>/dev/null

# ۲. قطع اتصالات فعلی کاربران غیر سیستمی برای هماهنگ‌سازی با دیتابیس پنل
echo "[*] Flushing old SSH connections for panel sync..."
sudo ps -eo user,pid | grep -E -v '^(root|sshd|nobody|daemon|systemd)' | awk '{print $2}' | xargs kill -9 2>/dev/null

# ۳. پیکربندی خودکار فایروال اوبونتو و باز کردن پورت‌های لازم
echo "[*] Configuring firewall rules and opening port 5000..."
sudo ufw allow 5000/tcp >/dev/null 2>&1
sudo ufw allow 22/tcp >/dev/null 2>&1
sudo ufw --force enable >/dev/null 2>&1
sudo ufw reload >/dev/null 2>&1

sudo iptables -I INPUT -p tcp --dport 5000 -j ACCEPT 2>/dev/null
sudo iptables -I INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null

# ۴. نصب پکیج‌های پیش‌نیاز سیستم‌عامل
sudo apt update -y
sudo apt install -y openssh-server python3 python3-flask sqlite3 psmisc coreutils python3-psutil

# ۵. ایجاد دایرکتوری اصلی پنل
sudo mkdir -p /etc/custom-panel
sudo chmod 755 /etc/custom-panel

# ۶. تزریق کد پایتون به همراه قالب فوق پیشرفته و بهینه
cat << 'EOF' > /etc/custom-panel/app.py
import os, subprocess, datetime, sqlite3, json, time, threading, pwd, psutil
from flask import Flask, request, render_template_string, redirect, send_file, jsonify

app = Flask(__name__)
app.secret_key = "ssh_pro_glass_dark_v11"
DB_FILE = "/etc/custom-panel/panel.db"
db_lock = threading.Lock()

LAST_PID_BYTES = {}

def get_db_connection():
    conn = sqlite3.connect(DB_FILE, timeout=30.0, check_same_thread=False)
    conn.execute('PRAGMA journal_mode=WAL;')
    conn.execute('PRAGMA synchronous=NORMAL;')
    return conn

def init_db():
    with db_lock:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS users (
                username TEXT PRIMARY KEY,
                password TEXT,
                limit_gb REAL,
                used_gb REAL DEFAULT 0.0,
                expire_date TEXT,
                status TEXT DEFAULT 'Active',
                initial_gb REAL,
                initial_days INTEGER
            )
        ''')
        conn.commit()
        conn.close()

def live_monitor_daemon():
    global LAST_PID_BYTES
    while True:
        try:
            today = datetime.datetime.now().strftime("%Y-%m-%d")
            active_pids_this_run = set()
            user_to_pids_map = {}
            
            for proc in psutil.process_iter(['pid', 'name', 'username']):
                try:
                    if 'sshd' in proc.info['name'].lower():
                        u = proc.info['username']
                        pid = str(proc.info['pid'])
                        if u not in ['root', 'sshd', 'nobody', 'none'] and 'net' not in u:
                            active_pids_this_run.add(pid)
                            user_to_pids_map.setdefault(u, []).append(pid)
                except: continue

            # قطع اتصالات همزمان (سیستم تک‌کاربره سخت‌گیرانه)
            for username, pids in user_to_pids_map.items():
                if len(pids) > 1:
                    pids.sort(key=int)
                    for old_pid in pids[:-1]:
                        try:
                            os.kill(int(old_pid), 9)
                        except: pass
                        if old_pid in LAST_PID_BYTES:
                            del LAST_PID_BYTES[old_pid]

            # محاسبه ترافیک مصرفی واقعی کاربران فعال
            with db_lock:
                conn = get_db_connection()
                cursor = conn.cursor()
                for username, pids in user_to_pids_map.items():
                    for active_pid in pids:
                        try:
                            with open(f"/proc/{active_pid}/net/dev", "r") as f:
                                net_data = f.read()
                            bytes_sum = 0
                            for net_line in net_data.split('\n'):
                                if ':' in net_line:
                                    net_parts = net_line.split()
                                    if len(net_parts) >= 10:
                                        bytes_sum += int(net_parts[1]) + int(net_parts[9])
                            
                            if active_pid in LAST_PID_BYTES:
                                diff = bytes_sum - LAST_PID_BYTES[active_pid]
                                if diff > 0:
                                    diff_gb = (diff / (1024.0 ** 3)) / 3.5
                                    cursor.execute("UPDATE users SET used_gb = used_gb + ? WHERE username = ? AND status='Active'", (diff_gb, username))
                            LAST_PID_BYTES[active_pid] = bytes_sum
                        except: pass
                conn.commit()
                conn.close()

            for dead_pid in list(LAST_PID_BYTES.keys()):
                if dead_pid not in active_pids_this_run:
                    del LAST_PID_BYTES[dead_pid]

            # قطع خودکار و تغییر وضعیت کاربران تمام حجم یا منقضی شده
            with db_lock:
                conn = get_db_connection()
                cursor = conn.cursor()
                cursor.execute("SELECT username, expire_date, limit_gb, used_gb FROM users WHERE status='Active'")
                for username, expire_date, limit_gb, used_gb in cursor.fetchall():
                    if (expire_date and expire_date < today) or (used_gb >= limit_gb):
                        subprocess.run(["sudo", "usermod", "-L", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        new_status = 'Expired' if (expire_date and expire_date < today) else 'Traffic_Limit'
                        cursor.execute("UPDATE users SET status=? WHERE username=?", (new_status, username))
                        subprocess.run(f"sudo pkill -9 -u {username}", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                conn.commit()
                conn.close()
        except: pass
        time.sleep(1.5)

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <title>SSH PREMIUM MANAGEMENT PANEL</title>
    <style>
        :root {
            --bg-color: #090d16;
            --card-bg: #111827;
            --border-color: #1f2937;
            --text-main: #f3f4f6;
            --text-muted: #9ca3af;
            --accent-blue: #0284c7;
            --accent-green: #10b981;
            --accent-red: #ef4444;
            --accent-orange: #f59e0b;
        }
        body { font-family: system-ui, -apple-system, sans-serif; background: var(--bg-color); color: var(--text-main); padding: 25px; margin: 0; }
        .container { max-width: 1300px; margin: auto; }
        
        .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 30px; }
        .header h2 { margin: 0; font-size: 22px; font-weight: 700; letter-spacing: -0.5px; }
        .header-btns { display: flex; gap: 10px; }
        
        .btn { padding: 8px 16px; border-radius: 6px; border: none; font-weight: 600; cursor: pointer; font-size: 13px; transition: all 0.2s; color: #fff; }
        .btn-primary { background: var(--accent-blue); }
        .btn-success { background: var(--accent-green); }
        .btn-danger { background: var(--accent-red); }
        .btn-warning { background: var(--accent-orange); }
        .btn-secondary { background: #374151; }
        .btn:hover { opacity: 0.9; }

        .stats-grid { display: grid; grid-template-columns: repeat(6, 1fr); gap: 15px; margin-bottom: 30px; }
        .stat-card { background: var(--card-bg); border: 1px solid var(--border-color); padding: 15px; border-radius: 10px; text-align: center; }
        .stat-card h4 { margin: 0 0 8px 0; color: var(--text-muted); font-size: 12px; font-weight: 500; }
        .stat-card .val { font-size: 20px; font-weight: 700; color: #fff; }

        .main-layout { display: grid; grid-template-columns: 2fr 1fr; gap: 20px; margin-bottom: 30px; }
        .panel-box { background: var(--card-bg); border: 1px solid var(--border-color); padding: 20px; border-radius: 12px; }
        .panel-box h3 { margin-top: 0; margin-bottom: 20px; font-size: 16px; font-weight: 600; border-right: 3px solid var(--accent-blue); padding-right: 8px; }
        
        .form-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; margin-bottom: 15px; }
        .form-group { display: flex; flex-direction: column; gap: 5px; }
        .form-group label { font-size: 12px; color: var(--text-muted); }
        .form-group input { background: #1f2937; border: 1px solid var(--border-color); padding: 10px; border-radius: 6px; color: #fff; font-size: 13px; outline: none; }
        .form-group input:focus { border-color: var(--accent-blue); }

        .search-bar { width: 100%; padding: 12px; background: var(--card-bg); border: 1px solid var(--border-color); border-radius: 8px; color: #fff; font-size: 14px; margin-bottom: 15px; box-sizing: border-box; outline: none; }
        .search-bar:focus { border-color: var(--accent-blue); }

        table { width: 100%; border-collapse: collapse; text-align: right; background: var(--card-bg); border-radius: 8px; overflow: hidden; border: 1px solid var(--border-color); }
        th, td { padding: 12px 15px; font-size: 13px; border-bottom: 1px solid var(--border-color); text-align: center; }
        th { background: #1f2937; color: var(--text-muted); font-weight: 500; }
        
        .badge { padding: 4px 8px; border-radius: 12px; font-size: 11px; font-weight: 600; }
        .badge-active { background: rgba(16, 185, 129, 0.1); color: var(--accent-green); }
        .badge-expired { background: rgba(239, 68, 68, 0.1); color: var(--accent-red); }
        .badge-limit { background: rgba(245, 158, 11, 0.1); color: var(--accent-orange); }
        
        .file-upload-label { display: block; border: 1px dashed #4b5563; padding: 20px; border-radius: 8px; text-align: center; cursor: pointer; color: var(--text-muted); font-size: 13px; transition: 0.2s; }
        .file-upload-label:hover { border-color: var(--accent-blue); color: #fff; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div>
                <span style="color: var(--accent-blue); font-size: 11px; font-weight: bold; letter-spacing: 2px;">MANAGEMENT</span>
                <h2>کنترل پنل مدیریت کاربران</h2>
            </div>
            <div class="header-btns">
                <a href="/backup/download"><button class="btn btn-secondary">📥 دانلود بک‌آپ</button></a>
                <button class="btn btn-danger">خروج</button>
            </div>
        </div>

        <div class="stats-grid">
            <div class="stat-card">
                <h4>RAM</h4>
                <div id="stat-ram" class="val">0.0%</div>
            </div>
            <div class="stat-card">
                <h4>مصرف کل</h4>
                <div id="stat-total-consumed" class="val">GB 0.0</div>
            </div>
            <div class="stat-card">
                <h4>حجم کل</h4>
                <div id="stat-total-limit" class="val">GB 0.0</div>
            </div>
            <div class="stat-card">
                <h4>آنلاین</h4>
                <div id="stat-online" class="val">0</div>
            </div>
            <div class="stat-card">
                <h4>فعال</h4>
                <div id="stat-active" class="val">0</div>
            </div>
            <div class="stat-card">
                <h4>کل کاربران</h4>
                <div id="stat-total-users" class="val">0</div>
            </div>
        </div>

        <div class="main-layout">
            <div class="panel-box">
                <h3>ساخت کاربر جدید</h3>
                <form action="/add" method="POST">
                    <div class="form-grid">
                        <div class="form-group">
                            <label>نام کاربری</label>
                            <input type="text" name="username" required autocomplete="off">
                        </div>
                        <div class="form-group">
                            <label>رمز عبور</label>
                            <input type="text" name="password" required autocomplete="off">
                        </div>
                    </div>
                    <div class="form-grid">
                        <div class="form-group">
                            <label>حجم (GB)</label>
                            <input type="number" step="0.1" name="limit_gb" value="10" required>
                        </div>
                        <div class="form-group">
                            <label>زمان (روز)</label>
                            <input type="number" name="days" value="30" required>
                        </div>
                    </div>
                    <button type="submit" class="btn btn-primary" style="width: 100%; padding: 12px; margin-top: 10px;">ساخت کاربر</button>
                </form>
            </div>

            <div style="display: flex; flex-direction: column; gap: 20px;">
                <div class="panel-box">
                    <h3>تنظیمات پورت و مدیریت</h3>
                    <div class="form-group" style="margin-bottom: 12px;">
                        <label>نام کاربری مدیر</label>
                        <input type="text" value="admin" disabled>
                    </div>
                    <div class="form-group" style="margin-bottom: 12px;">
                        <label>رمز عبور جدید مدیر</label>
                        <input type="text" placeholder="خالی بگذارید تا تغییر نکند">
                    </div>
                    <div class="form-group" style="margin-bottom: 15px;">
                        <label>پورت وب‌ساکت (SSHWS)</label>
                        <input type="number" value="80">
                    </div>
                    <button class="btn btn-primary" style="width: 100%;">ذخیره تنظیمات</button>
                </div>

                <div class="panel-box">
                    <h3>بازیابی اطلاعات</h3>
                    <form action="/backup/restore" method="POST" enctype="multipart/form-data" id="restoreForm">
                        <label class="file-upload-label" id="uploadLabel">
                            انتخاب فایل بک‌آپ
                            <input type="file" name="backup_file" id="backupFile" style="display: none;" onchange="document.getElementById('uploadLabel').innerText = this.files[0].name">
                        </label>
                        <button type="submit" class="btn btn-primary" style="width: 100%; margin-top: 15px;">بازیابی بک‌آپ</button>
                    </form>
                </div>
            </div>
        </div>

        <div class="panel-box" style="padding: 15px;">
            <h3>مدیریت کاربران</h3>
            <input type="text" id="search-bar" class="search-bar" placeholder="جستجو نام کاربری..." oninput="renderTable()">
            <table>
                <thead>
                    <tr>
                        <th>اطلاعات اتصال (User/Pass)</th>
                        <th>وضعیت حساب</th>
                        <th>اتصال زنده</th>
                        <th>مصرف دیتا</th>
                        <th>زمان باقی‌مانده</th>
                        <th>عملیات</th>
                    </tr>
                </thead>
                <tbody id="user-rows"></tbody>
            </table>
        </div>
    </div>

    <script>
        let allUsersData = [];
        let onlineList = [];

        async function updateData() {
            try {
                const res = await fetch('/api/users');
                const data = await res.json();
                allUsersData = data.users;
                onlineList = data.online;

                document.getElementById('stat-ram').innerText = data.ram + "%";
                document.getElementById('stat-total-users').innerText = allUsersData.length;
                document.getElementById('stat-online').innerText = onlineList.length;
                document.getElementById('stat-active').innerText = allUsersData.filter(u => u.status === 'Active').length;
                
                let totalConsumed = 0;
                let totalLimit = 0;
                allUsersData.forEach(u => {
                    totalConsumed += u.used_gb;
                    totalLimit += u.limit_gb;
                });
                document.getElementById('stat-total-consumed').innerText = "GB " + totalConsumed.toFixed(2);
                document.getElementById('stat-total-limit').innerText = "GB " + totalLimit.toFixed(1);

                renderTable();
            } catch(e) {}
        }

        function renderTable() {
            const tbody = document.getElementById('user-rows');
            const searchKeyword = document.getElementById('search-bar').value.trim().toLowerCase();
            tbody.innerHTML = '';

            allUsersData.forEach(user => {
                if (searchKeyword !== '' && !user.username.toLowerCase().includes(searchKeyword)) return;

                const isOnline = onlineList.map(o => o.trim().toLowerCase()).includes(user.username.trim().toLowerCase());
                const onlineBadge = isOnline ? '<span style="color:var(--accent-green); font-weight:bold;">● آنلاین (Live)</span>' : '<span style="color:var(--text-muted);">○ آفلاین</span>';
                
                let statusBadge = '<span class="badge badge-active">فعال</span>';
                if (user.status === 'Expired') statusBadge = '<span class="badge badge-expired">منقضی شده</span>';
                if (user.status === 'Traffic_Limit') statusBadge = '<span class="badge badge-limit">اتمام حجم</span>';
                if (user.status === 'Paused') statusBadge = '<span class="badge badge-limit" style="color:#9ca3af; background:rgba(255,255,255,0.05)">موقت متوقف</span>';

                const tr = document.createElement('tr');
                tr.innerHTML = `
                    <td style="text-align:right;">
                        <div style="font-weight:bold; color:#fff;">${user.username}</div>
                        <div style="font-size:11px; color:var(--text-muted);">رمز: ${user.password}</div>
                    </td>
                    <td>${statusBadge}</td>
                    <td>${onlineBadge}</td>
                    <td>
                        <div style="font-weight:bold;">${user.used_gb.toFixed(4)} / ${user.limit_gb} GB</div>
                        <div style="width:100%; background:#1f2937; height:4px; border-radius:2px; margin-top:4px; overflow:hidden;">
                            <div style="width:${Math.min((user.used_gb/user.limit_gb)*100, 100)}%; background:var(--accent-blue); height:100%;"></div>
                        </div>
                    </td>
                    <td>${user.remaining_days} روز</td>
                    <td>
                        <a href="/delete/${user.username}"><button class="btn btn-danger" style="padding:4px 8px; font-size:11px; margin-left:3px;">حذف</button></a>
                        <a href="/renew/${user.username}"><button class="btn btn-warning" style="padding:4px 8px; font-size:11px; margin-left:3px;">ریست</button></a>
                        <a href="/toggle/${user.username}"><button class="btn btn-secondary" style="padding:4px 8px; font-size:11px; background:#eab308; color:#000;">${user.status==='Paused'?'Active':'Pause'}</button></a>
                    </td>
                `;
                tbody.appendChild(tr);
            });
        }

        updateData();
        setInterval(updateData, 2000);
    </script>
</body>
</html>
"""

@app.route('/')
def index():
    return render_template_string(HTML_TEMPLATE)

@app.route('/api/users')
def api_users():
    try:
        with db_lock:
            conn = get_db_connection()
            cursor = conn.cursor()
            cursor.execute("SELECT username, password, limit_gb, used_gb, expire_date, status FROM users")
            rows = cursor.fetchall()
            conn.close()
        
        today = datetime.datetime.now().date()
        users_list = []
        for row in rows:
            username, password, limit_gb, used_gb, expire_date, status = row
            try:
                exp_date = datetime.datetime.strptime(expire_date, "%Y-%m-%d").date()
                remaining_days = (exp_date - today).days
                if remaining_days < 0: remaining_days = 0
            except: remaining_days = 0
                
            users_list.append({
                "username": username, "password": password, "limit_gb": limit_gb if limit_gb else 0.0,
                "used_gb": used_gb if used_gb else 0.0, "remaining_days": remaining_days, "status": status
            })
        
        online_now = []
        for proc in psutil.process_iter(['name', 'username']):
            try:
                if 'sshd' in proc.info['name'].lower():
                    u = proc.info['username']
                    if u not in ['root', 'sshd', 'nobody', 'none'] and 'net' not in u and u not in online_now:
                        online_now.append(u)
            except: pass
            
        ram_p = psutil.virtual_memory().percent
        return jsonify({"users": users_list, "online": online_now, "ram": ram_p})
    except:
        return jsonify({"users": [], "online": [], "ram": 0.0})

@app.route('/add', methods=['POST'])
def add_user():
    try:
        username = request.form['username'].strip()
        password = request.form['password'].strip()
        limit_gb = float(request.form['limit_gb'].strip())
        days = int(request.form['days'].strip())
        expire_date = (datetime.datetime.now() + datetime.timedelta(days=days)).strftime("%Y-%m-%d")
        
        safe_system_user_create(username, password)
        
        with db_lock:
            conn = get_db_connection()
            cursor = conn.cursor()
            cursor.execute("INSERT OR REPLACE INTO users (username, password, limit_gb, used_gb, expire_date, status, initial_gb, initial_days) VALUES (?, ?, ?, 0.0, ?, 'Active', ?, ?)",
                           (username, password, limit_gb, expire_date, limit_gb, days))
            conn.commit()
            conn.close()
    except: pass
    return redirect('/')

@app.route('/toggle/<username>')
def toggle_user(username):
    try:
        with db_lock:
            conn = get_db_connection()
            cursor = conn.cursor()
            cursor.execute("SELECT status FROM users WHERE username=?", (username,))
            row = cursor.fetchone()
            if row:
                current_status = row[0]
                new_status = 'Paused' if current_status == 'Active' else 'Active'
                cursor.execute("UPDATE users SET status=? WHERE username=?", (new_status, username))
                conn.commit()
                if new_status == 'Paused':
                    subprocess.run(["sudo", "usermod", "-L", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    subprocess.run(f"sudo pkill -9 -u {username}", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                else:
                    subprocess.run(["sudo", "usermod", "-U", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            conn.close()
    except: pass
    return redirect('/')

@app.route('/renew/<username>')
def renew_user(username):
    try:
        with db_lock:
            conn = get_db_connection()
            cursor = conn.cursor()
            cursor.execute("SELECT initial_gb, initial_days FROM users WHERE username=?", (username,))
            row = cursor.fetchone()
            if row:
                init_gb, init_days = row
                new_expire = (datetime.datetime.now() + datetime.timedelta(days=init_days)).strftime("%Y-%m-%d")
                cursor.execute("UPDATE users SET used_gb=0.0, limit_gb=?, expire_date=?, status='Active' WHERE username=?", 
                               (init_gb, new_expire, username))
                conn.commit()
                subprocess.run(["sudo", "usermod", "-U", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            conn.close()
    except: pass
    return redirect('/')

@app.route('/delete/<username>')
def delete_user(username):
    try:
        subprocess.run(f"sudo pkill -9 -u {username}", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["sudo", "userdel", "-r", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with db_lock:
            conn = get_db_connection()
            cursor = conn.cursor()
            cursor.execute("DELETE FROM users WHERE username=?", (username,))
            conn.commit()
            conn.close()
    except: pass
    return redirect('/')

@app.route('/backup/download')
def download_backup():
    try:
        with db_lock:
            conn = get_db_connection()
            cursor = conn.cursor()
            cursor.execute("SELECT username, password, limit_gb, used_gb, expire_date, status, initial_gb, initial_days FROM users")
            rows = cursor.fetchall()
            conn.close()
        backup_data = []
        for row in rows:
            backup_data.append({
                "username": row[0], "password": row[1], "limit_gb": row[2], "used_gb": row[3],
                "expire_date": row[4], "status": row[5], "initial_gb": row[6], "initial_days": row[7]
            })
        backup_filename = "/tmp/ssh_panel_backup.json"
        with open(backup_filename, "w") as f: json.dump(backup_data, f, indent=4)
        return send_file(backup_filename, as_attachment=True, download_name="ssh_panel_backup.json")
    except: return "Backup Error"

@app.route('/backup/restore', methods=['POST'])
def restore_backup():
    try:
        if 'backup_file' in request.files:
            file = request.files['backup_file']
            if file.filename != '':
                data = json.load(file)
                with db_lock:
                    conn = get_db_connection()
                    cursor = conn.cursor()
                    for item in data:
                        safe_system_user_create(item["username"], item["password"])
                        if item["status"] == "Active":
                            subprocess.run(["sudo", "usermod", "-U", item["username"]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        cursor.execute("""
                            INSERT OR REPLACE INTO users (username, password, limit_gb, used_gb, expire_date, status, initial_gb, initial_days)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """, (item["username"], item["password"], item["limit_gb"], item["used_gb"], item["expire_date"], item["status"], item["initial_gb"], item["initial_days"]))
                    conn.commit()
                    conn.close()
    except: pass
    return redirect('/')

def safe_system_user_create(username, password):
    try:
        pwd.getpwnam(username)
        subprocess.run(f"sudo pkill -9 -u {username}", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["sudo", "userdel", "-r", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except KeyError: pass
    subprocess.run(["sudo", "useradd", "-M", "-s", "/bin/false", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(f"echo '{username}:{password}' | sudo chpasswd", shell=True)

if __name__ == '__main__':
    init_db()
    threading.Thread(target=live_monitor_daemon, daemon=True).start()
    app.run(host='0.0.0.0', port=5000)
EOF

# ۷. لود دیمون‌ها و استارت مجدد سرویس سیستم‌عامل
sudo systemctl daemon-reload
sudo systemctl enable custom-panel.service
sudo systemctl restart custom-panel.service

echo "--------------------------------------------------"
echo "✔ PANEL SYNCED AND READY WITH LIVE RADAR MONITORING"
echo "🌐 PANEL ADDRESS: http://144.172.116.73:5000"
echo "--------------------------------------------------"
