#!/bin/bash

# بررسی دسترسی روت
if [ "$EUID" -ne 0 ]; then
  echo "لطفاً این اسکریپت را با دسترسی روت (root) اجرا کنید."
  exit 1
fi

echo "=================================================="
echo "    در حال نصب هسته فوق بهینه SSH-WS و پنل مدیریت...   "
echo "=================================================="

# آپدیت مخازن و نصب پیش‌نیازها
apt update -y
apt install -y python3 python3-pip python3-venv sqlite3 git curl net-tools ufw iptables

# ایجاد دایرکتوری پروژه
mkdir -p /root/ssh-panel
cd /root/ssh-panel

# ایجاد محیط مجازی پایتون جهت جلوگیری از تداخل بسته‌ها
python3 -m venv venv
source venv/bin/activate

# نصب کتابخانه‌های بهینه پایتون
pip install --upgrade pip
pip install fastapi uvicorn websockets jinja2 python-multipart

# ۱. ایجاد و بروزرسانی ساختار دیتابیس SQLite
sqlite3 /root/users.db <<EOF
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE,
    password TEXT,
    volume_limit REAL,
    volume_used REAL DEFAULT 0,
    expiry_date TEXT,
    status TEXT DEFAULT 'active',
    last_online TEXT DEFAULT 'N/A'
);
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT
);
INSERT OR IGNORE INTO settings (key, value) VALUES ('admin_username', 'admin');
INSERT OR IGNORE INTO settings (key, value) VALUES ('admin_password', 'admin');
INSERT OR IGNORE INTO settings (key, value) VALUES ('ws_port', '80');
EOF

# ۲. ساخت فایل فرانت‌اند (HTML/CSS/JS) دارک و بهینه با بروزرسانی زنده
mkdir -p templates
cat << 'EOF' > templates/index.html
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <title>کنترل پنل مدیریت کاربران</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.rtl.min.css" rel="stylesheet">
    <style>
        body { background-color: #0b0f19; color: #f1f5f9; font-family: system-ui, -apple-system, sans-serif; }
        .card-stat { background-color: #111827; border: 1px solid #1f2937; border-radius: 12px; padding: 15px; text-align: center; }
        .card-stat h5 { color: #9ca3af; font-size: 0.9rem; }
        .card-stat p { font-size: 1.5rem; font-weight: bold; margin: 0; color: #38bdf8; }
        .box-container { background-color: #111827; border: 1px solid #1f2937; border-radius: 12px; padding: 20px; margin-bottom: 20px; }
        .box-title { font-size: 1.1rem; font-weight: bold; margin-bottom: 20px; border-bottom: 1px solid #1f2937; padding-bottom: 10px; display: flex; justify-content: space-between; }
        .badge-type { font-size: 0.75rem; padding: 3px 8px; border-radius: 5px; background-color: #3b82f6; }
        .table-custom { background-color: #111827; color: #f1f5f9; }
        .table-custom th { color: #9ca3af; border-bottom: 1px solid #1f2937; }
        .table-custom td { border-bottom: 1px solid #1f2937; vertical-align: middle; }
        .btn-custom-blue { background-color: #2563eb; color: white; border: none; }
        .btn-custom-blue:hover { background-color: #1d4ed8; color: white; }
        .form-control { background-color: #1f2937; border: 1px solid #374151; color: white; }
        .form-control:focus { background-color: #1f2937; border-color: #3b82f6; color: white; box-shadow: none; }
    </style>
</head>
<body>
    <div class="container my-4">
        <div class="d-flex justify-content-between align-items-center mb-4">
            <h4 class="fw-bold"><span class="badge bg-primary me-2">CP</span> کنترل پنل مدیریت کاربران</h4>
            <div>
                <button class="btn btn-outline-success btn-sm me-2" onclick="downloadBackup()">دانلود بکاپ</button>
            </div>
        </div>

        <div class="row g-3 mb-4">
            <div class="col-md-2 col-6"><div class="card-stat"><h5>کل کاربران</h5><p id="stat-total">0</p></div></div>
            <div class="col-md-2 col-6"><div class="card-stat"><h5>فعال</h5><p id="stat-active" style="color: #10b981;">0</p></div></div>
            <div class="col-md-2 col-6"><div class="card-stat"><h5>آنلاین</h5><p id="stat-online" style="color: #f59e0b;">0</p></div></div>
            <div class="col-md-3 col-6"><div class="card-stat"><h5>حجم کل (GB)</h5><p id="stat-total-volume">0.0</p></div></div>
            <div class="col-md-3 col-12"><div class="card-stat"><h5>مصرف کل (GB)</h5><p id="stat-used-volume">0.0</p></div></div>
        </div>

        <div class="row">
            <div class="col-md-6">
                <div class="box-container">
                    <div class="box-title"><span>ساخت کاربر جدید</span><span class="badge-type">USER</span></div>
                    <form id="create-user-form">
                        <div class="row g-3">
                            <div class="col-6"><label class="form-label">نام کاربری</label><input type="text" id="new-username" class="form-control" required></div>
                            <div class="col-6"><label class="form-label">رمز عبور</label><input type="text" id="new-password" class="form-control" required></div>
                            <div class="col-6"><label class="form-label">حجم (GB)</label><input type="number" id="new-volume" class="form-control" value="10" required></div>
                            <div class="col-6"><label class="form-label">زمان (روز)</label><input type="number" id="new-days" class="form-control" value="30" required></div>
                        </div>
                        <button type="submit" class="btn btn-custom-blue w-100 mt-4">ساخت کاربر</button>
                    </form>
                </div>
            </div>

            <div class="col-md-6">
                <div class="box-container">
                    <div class="box-title"><span>تنظیمات پورت و مدیریت</span><span class="badge-type" style="background-color: #a855f7;">PORT</span></div>
                    <form id="settings-form">
                        <div class="mb-3"><label class="form-label">نام کاربری مدیر</label><input type="text" id="admin-user" class="form-control" required></div>
                        <div class="mb-3"><label class="form-label">رمز عبور جدید مدیر</label><input type="password" id="admin-pass" class="form-control" placeholder="خالی بگذارید تا تغییر نکند"></div>
                        <div class="mb-3"><label class="form-label">پورت وب‌ساکت (SSHWS)</label><input type="number" id="ws-port" class="form-control" required></div>
                        <button type="submit" class="btn btn-custom-blue w-100">ذخیره تنظیمات</button>
                    </form>
                </div>
            </div>
        </div>

        <div class="box-container mt-4">
            <div class="box-title">مدیریت کاربران</div>
            <div class="table-responsive">
                <table class="table table-custom text-center">
                    <thead>
                        <tr>
                            <th>اطلاعات اتصال (User/Pass)</th>
                            <th>وضعیت حساب</th>
                            <th>اتصال زنده</th>
                            <th>مصرف دیتا (دریافتی / کل)</th>
                            <th>زمان باقی‌مانده</th>
                            <th>عملیات</th>
                        </tr>
                    </thead>
                    <tbody id="users-table-body"></tbody>
                </table>
            </div>
        </div>
    </div>

    <script>
        // برقراری ارتباط وب‌ساکت به منظور مانیتورینگ Real-time
        let protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        let wsUrl = `${protocol}//${window.location.host}/api/live-stats`;
        let liveWs;

        function connectLiveStats() {
            liveWs = new WebSocket(wsUrl);
            liveWs.onmessage = function(event) {
                const data = JSON.parse(event.data);
                
                document.getElementById('stat-total').innerText = data.stats.total;
                document.getElementById('stat-active').innerText = data.stats.active;
                document.getElementById('stat-online').innerText = data.stats.online;
                document.getElementById('stat-total-volume').innerText = data.stats.total_volume.toFixed(1);
                document.getElementById('stat-used-volume').innerText = data.stats.used_volume.toFixed(4);

                if(data.settings) {
                    document.getElementById('admin-user').value = data.settings.admin_username;
                    document.getElementById('ws-port').value = data.settings.ws_port;
                }

                const tbody = document.getElementById('users-table-body');
                tbody.innerHTML = '';
                data.users.forEach(u => {
                    const statusBadge = u.status === 'active' ? '<span class="badge bg-success">فعال</span>' : '<span class="badge bg-danger">مسدود</span>';
                    const onlineBadge = u.is_online ? '<span class="badge bg-warning text-dark">● آنلاین</span>' : `<span class="text-muted small">${u.last_online}</span>`;
                    const percent = Math.min((u.volume_used / u.volume_limit) * 100, 100);
                    
                    tbody.innerHTML += `
                        <tr>
                            <td><strong>${u.username}</strong><br><span class="text-muted small">رمز: ${u.password}</span></td>
                            <td>${statusBadge}</td>
                            <td>${onlineBadge}</td>
                            <td>
                                <div class="progress" style="height: 6px; background-color:#1f2937;">
                                    <div class="progress-bar" style="width: ${percent}%"></div>
                                </div>
                                <small>${u.volume_used.toFixed(4)} / ${u.volume_limit} GB</small>
                            </td>
                            <td>${u.days_left} روز</td>
                            <td>
                                <button class="btn btn-sm btn-danger me-1" onclick="deleteUser('${u.username}')">حذف</button>
                                <button class="btn btn-sm btn-warning me-1" onclick="toggleUser('${u.username}')">${u.status === 'active' ? 'Pause' : 'Active'}</button>
                                <button class="btn btn-sm btn-info" onclick="resetTraffic('${u.username}')">ریست</button>
                            </td>
                        </tr>
                    `;
                });
            };
            liveWs.onclose = function() {
                setTimeout(connectLiveStats, 2000); // تلاش مجدد در صورت قطعی شبکه
            };
        }

        document.getElementById('settings-form').addEventListener('submit', async (e) => {
            e.preventDefault();
            const admin_username = document.getElementById('admin-user').value;
            const admin_password = document.getElementById('admin-pass').value;
            const ws_port = document.getElementById('ws-port').value;

            const res = await fetch('/api/settings', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({admin_username, admin_password, ws_port})
            });
            alert("تنظیمات ذخیره شد. پورت فایروال فوراً آپدیت گردید.");
        });

        async function deleteUser(username) {
            if(confirm(`حذف کاربر ${username}؟`)) await fetch(`/api/user/delete/${username}`, {method: 'POST'});
        }
        async function toggleUser(username) {
            await fetch(`/api/user/toggle/${username}`, {method: 'POST'});
        }
        async function resetTraffic(username) {
            await fetch(`/api/user/reset/${username}`, {method: 'POST'});
        }

        document.getElementById('create-user-form').addEventListener('submit', async (e) => {
            e.preventDefault();
            const username = document.getElementById('new-username').value;
            const password = document.getElementById('new-password').value;
            const limit = document.getElementById('new-volume').value;
            const days = document.getElementById('new-days').value;

            await fetch('/api/user/create', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({username, password, limit, days})
            });
            document.getElementById('create-user-form').reset();
        });

        function downloadBackup() { window.location.href = '/api/backup'; }
        
        // استارت مانیتورینگ در زمان لود صفحه
        connectLiveStats();
    </script>
</body>
</html>
EOF

# ۳. ایجاد اسکریپت پایتون پیشرفته و ۱۰۰٪ ناهمگام (FastAPI + Asynchronous WS Tunnel)
cat << 'EOF' > main.py
import asyncio
import sqlite3
import os
import json
from datetime import datetime, timedelta
from fastapi import FastAPI, Request, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, FileResponse
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel

app = FastAPI()
templates = Jinja2Templates(directory="templates")

DB_PATH = "/root/users.db"

# کش‌های مقیم در رم برای سرعت استثنایی و پینگ صفر
active_users_cache = {}      # نام کاربری کلاینت‌های متصل به عنوان کلید
realtime_traffic_cache = {}  # حجم دریافتی در لحظه درون حافظه موقت {username: GB}
admin_ws_listeners = set()   # لیست مرورگرهای ادمین باز نگه داشته شده

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

class UserCreate(BaseModel):
    username: str
    password: str
    limit: float
    days: int

class SettingsUpdate(BaseModel):
    admin_username: str
    admin_password: str
    ws_port: str

# تسک پس‌زمینه مداوم و سبک جهت ارسال کل دیتای Real-time به وب‌ساکت ادمین (هر ۱ ثانیه یکبار)
async def broadcast_to_admins_loop():
    while True:
        await asyncio.sleep(1.0)
        if not admin_ws_listeners:
            continue
            
        try:
            conn = get_db()
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM settings")
            settings_rows = cursor.fetchall()
            settings_dict = {row['key']: row['value'] for row in settings_rows}

            cursor.execute("SELECT * FROM users")
            db_users = cursor.fetchall()
            conn.close()
            
            users_list = []
            total_volume = 0.0
            used_volume = 0.0
            active_count = 0
            online_count = len(active_users_cache)
            
            for row in db_users:
                u = dict(row)
                uname = u['username']
                
                # ادغام حجم لحظه‌ای موجود در رم با حجم ذخیره شده دیتابیس
                live_extra = realtime_traffic_cache.get(uname, 0.0)
                current_used = u['volume_used'] + live_extra
                
                exp = datetime.strptime(u['expiry_date'], "%Y-%m-%d")
                days_left = max((exp - datetime.now()).days, 0)
                
                is_online = uname in active_users_cache
                
                users_list.append({
                    "username": uname,
                    "password": u["password"],
                    "volume_limit": u["volume_limit"],
                    "volume_used": current_used,
                    "days_left": days_left,
                    "status": u["status"],
                    "is_online": is_online,
                    "last_online": u["last_online"]
                })
                
                total_volume += u["volume_limit"]
                used_volume += current_used
                if u["status"] == "active":
                    active_count += 1
                    
            payload = {
                "stats": {
                    "total": len(users_list),
                    "active": active_count,
                    "online": online_count,
                    "total_volume": total_volume,
                    "used_volume": used_volume
                },
                "settings": settings_dict,
                "users": users_list
            }
            
            # برودکست ناهمگام به تمام ادمین‌ها بدون ایجاد گلوگاه
            message = json.dumps(payload)
            for ws in list(admin_ws_listeners):
                try:
                    await ws.send_text(message)
                except Exception:
                    admin_ws_listeners.remove(ws)
        except Exception:
            pass

# تسک همگام‌سازی دوره‌ای حجم رم با هارد دیسک (هر ۱۰ ثانیه) برای محافظت از سلامت سخت‌افزار
async def flush_traffic_to_db_loop():
    while True:
        await asyncio.sleep(10.0)
        if not realtime_traffic_cache:
            continue
        try:
            conn = sqlite3.connect(DB_PATH)
            cursor = conn.cursor()
            for uname, extra_gb in list(realtime_traffic_cache.items()):
                if extra_gb > 0:
                    cursor.execute("UPDATE users SET volume_used = volume_used + ? WHERE username = ?", (extra_gb, uname))
                    realtime_traffic_cache[uname] = 0.0
            conn.commit()
            conn.close()
        except Exception:
            pass

@app.on_event("startup")
async def startup_event():
    asyncio.create_task(broadcast_to_admins_loop())
    asyncio.create_task(flush_traffic_to_db_loop())
    
    # راه‌اندازی اولیه تانل وب‌ساکت کاربران بر اساس پورت ذخیره شده
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT value FROM settings WHERE key='ws_port'")
    port = cursor.fetchone()[0]
    conn.close()
    await apply_firewall_and_restart_tunnel(int(port))

# وب‌ساکت مانیتورینگ پنل ادمین
@app.websocket("/api/live-stats")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    admin_ws_listeners.add(websocket)
    try:
        while True:
            await websocket.receive_text() # زنده نگه داشتن کانکشن
    except WebSocketDisconnect:
        admin_ws_listeners.remove(websocket)

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})

@app.post("/api/user/create")
async def create_user(user: UserCreate):
    conn = get_db()
    cursor = conn.cursor()
    expiry = (datetime.now() + timedelta(days=user.days)).strftime("%Y-%m-%d")
    try:
        cursor.execute("INSERT INTO users (username, password, volume_limit, expiry_date) VALUES (?, ?, ?, ?)",
                       (user.username, user.password, user.limit, expiry))
        conn.commit()
        os.system(f"useradd -m -s /bin/false {user.username} > /dev/null 2>&1")
        os.system(f"echo '{user.username}:{user.password}' | chpasswd > /dev/null 2>&1")
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=400, detail="User already exists")
    finally:
        conn.close()
    return {"status": "success"}

@app.post("/api/user/delete/{username}")
async def delete_user(username: str):
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("DELETE FROM users WHERE username = ?", (username,))
    conn.commit()
    conn.close()
    os.system(f"userdel -r {username} > /dev/null 2>&1")
    return {"status": "success"}

@app.post("/api/user/toggle/{username}")
async def toggle_user(username: str):
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT status FROM users WHERE username = ?", (username,))
    user = cursor.fetchone()
    if user:
        new_status = 'suspended' if user['status'] == 'active' else 'active'
        cursor.execute("UPDATE users SET status = ? WHERE username = ?", (new_status, username))
        conn.commit()
        if new_status == 'suspended':
            os.system(f"usermod -L {username} > /dev/null 2>&1")
        else:
            os.system(f"usermod -U {username} > /dev/null 2>&1")
    conn.close()
    return {"status": "success"}

@app.post("/api/user/reset/{username}")
async def reset_traffic(username: str):
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("UPDATE users SET volume_used = 0 WHERE username = ?", (username,))
    conn.commit()
    conn.close()
    if username in realtime_traffic_cache:
        realtime_traffic_cache[username] = 0.0
    return {"status": "success"}

# پردازش تغییر تنظیمات و آپدیت آنی پورت کلاینت‌ها بدون قطعی کل پنل
async def apply_firewall_and_restart_tunnel(port):
    # مسدود کردن پورت‌های وب‌ساکت قدیمی احتمالی و باز کردن پورت جدید در iptables/ufw
    os.system("ufw disable > /dev/null 2>&1")
    os.system(f"iptables -t nat -F > /dev/null 2>&1")
    # ریدایرکت بومی لینوکس در لایه هسته (Kernel) برای رسیدن به بالاترین سرعت و پینگ صفر
    # ترافیک ورودی وب‌ساکت را مستقیماً به پورت بک‌اند پایتون هدایت می‌کند
    os.system(f"iptables -t nat -A PREROUTING -p tcp --dport {port} -j REDIRECT --to-port 8001 > /dev/null 2>&1")

@app.post("/api/settings")
async def save_settings(payload: SettingsUpdate):
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('admin_username', ?)", (payload.admin_username,))
    if payload.admin_password:
        cursor.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('admin_password', ?)", (payload.admin_password,))
    cursor.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('ws_port', ?)", (payload.ws_port,))
    conn.commit()
    conn.close()
    
    await apply_firewall_and_restart_tunnel(int(payload.ws_port))
    return {"status": "success"}

@app.get("/api/backup")
async def download_backup():
    return FileResponse(DB_PATH, media_type="application/octet-stream", filename="users_backup.db")

# ------------------------------------------------------------------------
# هسته تانل انتقال دیتا فوق سریع SSH-WS (اجرا روی پورت داخلی 8001)
# ------------------------------------------------------------------------
import websockets

async def ssh_ws_tunnel_handler(websocket, path):
    username = "unknown"
    path_parts = path.strip("/").split("/")
    if len(path_parts) > 0 and path_parts[0]:
        username = path_parts[0]
        
    active_users_cache[username] = datetime.now()
    
    try:
        # متصل شدن مستقیم به پورت ۲۲ لوکال سرور با کمترین تاخیر
        reader, writer = await asyncio.open_connection('127.0.0.1', 22)
        
        async def ws_to_ssh():
            try:
                async for message in websocket:
                    writer.write(message)
                    await writer.drain()
            except Exception:
                pass
            finally:
                writer.close()

        async def ssh_to_ws():
            try:
                while True:
                    data = await reader.read(16384) # افزایش سایز بافر به ۱۶ کیلوبایت جهت بیشینه‌سازی پهنای باند کاربران ایرانی
                    if not data:
                        break
                    await websocket.send(data)
                    
                    # محاسبه آنی حجم کلاینت در رم سرور
                    bytes_len = len(data)
                    gb_val = bytes_len / (1024 ** 3)
                    realtime_traffic_cache[username] = realtime_traffic_cache.get(username, 0.0) + gb_val
            except Exception:
                pass

        await asyncio.gather(ws_to_ssh(), ssh_to_ws())
    except Exception:
        pass
    finally:
        if username in active_users_cache:
            conn = sqlite3.connect(DB_PATH)
            cursor = conn.cursor()
            now_str = datetime.now().strftime("%H:%M:%S")
            cursor.execute("UPDATE users SET last_online = ? WHERE username = ?", (now_str, username))
            conn.commit()
            conn.close()
            del active_users_cache[username]

def start_tunnel_worker():
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    start_server = websockets.serve(ssh_ws_tunnel_handler, "0.0.0.0", 8001)
    loop.run_until_complete(start_server)
    loop.run_forever()

if __name__ == "__main__":
    import threading
    # انتقال بار ترافیکی کلاینت‌ها به یک Thread مجزا جهت جلوگیری از فریز شدن وب پنل
    threading.Thread(target=start_tunnel_worker, daemon=True).start()
    
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
EOF

# ۴. تنطیم خودکار سرویس پایدار پیش‌فرض سیستم‌عامل
cat << 'EOF' > /etc/systemd/system/ssh-panel.service
[Unit]
Description=SSH Realtime WS Panel Engine
After=network.target

[Service]
User=root
WorkingDirectory=/root/ssh-panel
ExecStart=/root/ssh-panel/venv/bin/python3 main.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ssh-panel.service
systemctl restart ssh-panel.service

echo "=================================================="
echo "پنل فوق بهینه و Real-time با موفقیت آپدیت شد!"
echo "آدرس پنل مدیریت شما: http://YOUR_SERVER_IP:8000"
echo "=================================================="
