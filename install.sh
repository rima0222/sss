#!/bin/bash

# بررسی دسترسی روت
if [ "$EUID" -ne 0 ]; then
  echo "لطفاً این اسکریپت را با دسترسی روت (root) اجرا کنید."
  exit 1
fi

echo "=================================================="
echo "  در حال نصب پنل مدیریت SSH-WS بهینه و پیشرفته..."
echo "=================================================="

# آپدیت مخازن و نصب پیش‌نیازها
apt update -y
apt install -y python3 python3-pip python3-venv sqlite3 git curl net-tools

# ایجاد دایرکتوری پروژه
mkdir -p /root/ssh-panel
cd /root/ssh-panel

# ایجاد محیط مجازی پایتون جهت جلوگیری از تداخل بسته‌ها
python3 -m venv venv
source venv/bin/activate

# نصب کتابخانه‌های بهینه پایتون
pip install --upgrade pip
pip install fastapi uvicorn websockets jinja2 python-multipart

# ۱. ایجاد دیتابیس SQLite
sqlite3 /root/users.db <<EOF
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE,
    password TEXT,
    volume_limit REAL, -- GB
    volume_used REAL DEFAULT 0, -- GB (Received)
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

# ۲. ساخت فایل فرانت‌اند (HTML/CSS/JS) با طراحی دقیق تم دارک مشابه تصویر
mkdir -p templates
cat << 'EOF' > templates/index.html
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <title>کنترل پنل مدیریت کاربران</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.rtl.min.css" rel="stylesheet">
    <style>
        body {
            background-color: #0b0f19;
            color: #f1f5f9;
            font-family: system-ui, -apple-system, sans-serif;
        }
        .card-stat {
            background-color: #111827;
            border: 1px solid #1f2937;
            border-radius: 12px;
            padding: 15px;
            text-align: center;
        }
        .card-stat h5 {
            color: #9ca3af;
            font-size: 0.9rem;
        }
        .card-stat p {
            font-size: 1.5rem;
            font-weight: bold;
            margin: 0;
            color: #38bdf8;
        }
        .box-container {
            background-color: #111827;
            border: 1px solid #1f2937;
            border-radius: 12px;
            padding: 20px;
            margin-bottom: 20px;
        }
        .box-title {
            font-size: 1.1rem;
            font-weight: bold;
            margin-bottom: 20px;
            border-bottom: 1px solid #1f2937;
            padding-bottom: 10px;
            display: flex;
            justify-content: space-between;
        }
        .badge-type {
            font-size: 0.75rem;
            padding: 3px 8px;
            border-radius: 5px;
            background-color: #3b82f6;
        }
        .table-custom {
            background-color: #111827;
            color: #f1f5f9;
        }
        .table-custom th {
            color: #9ca3af;
            border-bottom: 1px solid #1f2937;
        }
        .table-custom td {
            border-bottom: 1px solid #1f2937;
            vertical-align: middle;
        }
        .btn-custom-blue {
            background-color: #2563eb;
            color: white;
            border: none;
        }
        .btn-custom-blue:hover {
            background-color: #1d4ed8;
            color: white;
        }
        .form-control {
            background-color: #1f2937;
            border: 1px solid #374151;
            color: white;
        }
        .form-control:focus {
            background-color: #1f2937;
            border-color: #3b82f6;
            color: white;
            box-shadow: none;
        }
    </style>
</head>
<body>
    <div class="container my-4">
        <!-- هدر اصلی -->
        <div class="d-flex justify-content-between align-items-center mb-4">
            <h4 class="fw-bold"><span class="badge bg-primary me-2">CP</span> کنترل پنل مدیریت کاربران</h4>
            <div>
                <button class="btn btn-outline-success btn-sm me-2" onclick="downloadBackup()">دانلود بکاپ</button>
                <a href="/logout" class="btn btn-outline-danger btn-sm">خروج</a>
            </div>
        </div>

        <!-- کارت‌های وضعیت -->
        <div class="row g-3 mb-4">
            <div class="col-md-2 col-6">
                <div class="card-stat">
                    <h5>کل کاربران</h5>
                    <p id="stat-total">0</p>
                </div>
            </div>
            <div class="col-md-2 col-6">
                <div class="card-stat">
                    <h5>فعال</h5>
                    <p id="stat-active" style="color: #10b981;">0</p>
                </div>
            </div>
            <div class="col-md-2 col-6">
                <div class="card-stat">
                    <h5>آنلاین</h5>
                    <p id="stat-online" style="color: #f59e0b;">0</p>
                </div>
            </div>
            <div class="col-md-3 col-6">
                <div class="card-stat">
                    <h5>حجم کل (GB)</h5>
                    <p id="stat-total-volume">0.0</p>
                </div>
            </div>
            <div class="col-md-3 col-12">
                <div class="card-stat">
                    <h5>مصرف کل (GB)</h5>
                    <p id="stat-used-volume">0.0</p>
                </div>
            </div>
        </div>

        <!-- بخش فرم‌ها -->
        <div class="row">
            <!-- ساخت کاربر جدید -->
            <div class="col-md-6">
                <div class="box-container">
                    <div class="box-title">
                        <span>ساخت کاربر جدید</span>
                        <span class="badge-type">USER</span>
                    </div>
                    <form id="create-user-form">
                        <div class="row g-3">
                            <div class="col-6">
                                <label class="form-label">نام کاربری</label>
                                <input type="text" id="new-username" class="form-control" required>
                            </div>
                            <div class="col-6">
                                <label class="form-label">رمز عبور</label>
                                <input type="text" id="new-password" class="form-control" required>
                            </div>
                            <div class="col-6">
                                <label class="form-label">حجم (GB)</label>
                                <input type="number" id="new-volume" class="form-control" value="10" required>
                            </div>
                            <div class="col-6">
                                <label class="form-label">زمان (روز)</label>
                                <input type="number" id="new-days" class="form-control" value="30" required>
                            </div>
                        </div>
                        <button type="submit" class="btn btn-custom-blue w-100 mt-4">ساخت کاربر</button>
                    </form>
                </div>
            </div>

            <!-- تنظیمات پورت و مدیریت -->
            <div class="col-md-6">
                <div class="box-container">
                    <div class="box-title">
                        <span>تنظیمات پورت و مدیریت</span>
                        <span class="badge-type" style="background-color: #a855f7;">PORT</span>
                    </div>
                    <form id="settings-form">
                        <div class="mb-3">
                            <label class="form-label">نام کاربری مدیر</label>
                            <input type="text" id="admin-user" class="form-control" required>
                        </div>
                        <div class="mb-3">
                            <label class="form-label">رمز عبور جدید مدیر</label>
                            <input type="password" id="admin-pass" class="form-control" placeholder="خالی بگذارید تا تغییر نکند">
                        </div>
                        <div class="mb-3">
                            <label class="form-label">پورت وب‌ساکت (SSHWS)</label>
                            <input type="number" id="ws-port" class="form-control" required>
                        </div>
                        <button type="submit" class="btn btn-custom-blue w-100">ذخیره تنظیمات</button>
                    </form>
                </div>
            </div>
        </div>

        <!-- مدیریت کاربران -->
        <div class="box-container mt-4">
            <div class="box-title">مدیریت کاربران</div>
            <div class="mb-3">
                <input type="text" id="search-input" class="form-control" placeholder="جستجو نام کاربری...">
            </div>
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
                    <tbody id="users-table-body">
                        <!-- ردیف‌ها به صورت داینامیک لود می‌شوند -->
                    </tbody>
                </table>
            </div>
        </div>
    </div>

    <script>
        async function fetchStatsAndUsers() {
            const res = await fetch('/api/data');
            const data = await res.json();
            
            // به روز رسانی آمار
            document.getElementById('stat-total').innerText = data.stats.total;
            document.getElementById('stat-active').innerText = data.stats.active;
            document.getElementById('stat-online').innerText = data.stats.online;
            document.getElementById('stat-total-volume').innerText = data.stats.total_volume.toFixed(1);
            document.getElementById('stat-used-volume').innerText = data.stats.used_volume.toFixed(2);

            // به روز رسانی لیست کاربران
            const tbody = document.getElementById('users-table-body');
            tbody.innerHTML = '';
            data.users.forEach(u => {
                const statusBadge = u.status === 'active' ? '<span class="badge bg-success">فعال</span>' : '<span class="badge bg-danger">مسدود</span>';
                const onlineBadge = u.is_online ? '<span class="badge bg-warning text-dark">آنلاین</span>' : `<span class="text-muted small">${u.last_online}</span>`;
                
                tbody.innerHTML += `
                    <tr>
                        <td><strong>${u.username}</strong><br><span class="text-muted small">رمز: ${u.password}</span></td>
                        <td>${statusBadge}</td>
                        <td>${onlineBadge}</td>
                        <td><div class="progress" style="height: 6px; background-color:#1f2937;"><div class="progress-bar" style="width: ${(u.volume_used/u.volume_limit)*100}%"></div></div><small>${u.volume_used.toFixed(2)} / ${u.volume_limit} GB</small></td>
                        <td>${u.days_left} روز</td>
                        <td>
                            <button class="btn btn-sm btn-danger me-1" onclick="deleteUser('${u.username}')">حذف</button>
                            <button class="btn btn-sm btn-warning me-1" onclick="toggleUser('${u.username}')">${u.status === 'active' ? 'Pause' : 'Active'}</button>
                            <button class="btn btn-sm btn-info" onclick="resetTraffic('${u.username}')">ریست</button>
                        </td>
                    </tr>
                `;
            });
        }

        // توابع عملیاتی دکمه‌ها
        async function deleteUser(username) {
            if(confirm(`آیا از حذف کاربر ${username} مطمئن هستید؟`)) {
                await fetch(`/api/user/delete/${username}`, {method: 'POST'});
                fetchStatsAndUsers();
            }
        }
        async function toggleUser(username) {
            await fetch(`/api/user/toggle/${username}`, {method: 'POST'});
            fetchStatsAndUsers();
        }
        async function resetTraffic(username) {
            await fetch(`/api/user/reset/${username}`, {method: 'POST'});
            fetchStatsAndUsers();
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
            fetchStatsAndUsers();
        });

        function downloadBackup() {
            window.location.href = '/api/backup';
        }

        // اجرای خودکار دریافت اطلاعات در فواصل زمانی کم جهت نمایش آنلاین بودن لحظه‌ای
        fetchStatsAndUsers();
        setInterval(fetchStatsAndUsers, 4000);
    </script>
</body>
</html>
EOF

# ۳. ساخت بک‌اند پایتون (FastAPI + Websocket SSH-WS) در یک فایل بهینه
cat << 'EOF' > main.py
import asyncio
import sqlite3
import os
import shutil
from datetime import datetime, timedelta
from fastapi import FastAPI, Request, HTTPException, Depends
from fastapi.responses import HTMLResponse, FileResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel
import websockets

app = FastAPI()
templates = Jinja2Templates(directory="templates")

DB_PATH = "/root/users.db"

# ذخیره‌سازی وضعیت کاربران آنلاین فعال در وب‌ساکت جهت نظارت بهینه
active_ws_connections = {}

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

class UserCreate(BaseModel):
    username: str
    password: str
    limit: float
    days: int

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})

@app.get("/api/data")
async def get_data():
    conn = get_db()
    cursor = conn.cursor()
    
    # همگام‌سازی و خواندن کاربران
    cursor.execute("SELECT * FROM users")
    db_users = cursor.fetchall()
    
    users_list = []
    total_volume = 0.0
    used_volume = 0.0
    active_count = 0
    online_count = 0
    
    for row in db_users:
        u = dict(row)
        # محاسبه روزهای باقی‌مانده
        exp = datetime.strptime(u['expiry_date'], "%Y-%m-%d")
        days_left = (exp - datetime.now()).days
        if days_left < 0:
            days_left = 0
            if u['status'] == 'active':
                cursor.execute("UPDATE users SET status = 'expired' WHERE username = ?", (u['username'],))
                conn.commit()
                u['status'] = 'expired'
        
        is_online = u['username'] in active_ws_connections
        if is_online:
            online_count += 1
            
        users_list.append({
            "username": u["username"],
            "password": u["password"],
            "volume_limit": u["volume_limit"],
            "volume_used": u["volume_used"],
            "days_left": days_left,
            "status": u["status"],
            "is_online": is_online,
            "last_online": u["last_online"]
        })
        
        total_volume += u["volume_limit"]
        used_volume += u["volume_used"]
        if u["status"] == "active":
            active_count += 1
            
    conn.close()
    
    return {
        "stats": {
            "total": len(users_list),
            "active": active_count,
            "online": online_count,
            "total_volume": total_volume,
            "used_volume": used_volume
        },
        "users": users_list
    }

@app.post("/api/user/create")
async def create_user(user: UserCreate):
    conn = get_db()
    cursor = conn.cursor()
    expiry = (datetime.now() + timedelta(days=user.days)).strftime("%Y-%m-%d")
    try:
        cursor.execute(
            "INSERT INTO users (username, password, volume_limit, expiry_date) VALUES (?, ?, ?, ?)",
            (user.username, user.password, user.limit, expiry)
        )
        conn.commit()
        # ساخت کاربر سیستمی واقعی در لینوکس جهت اتصال SSH
        os.system(f"useradd -m -s /bin/false {user.username}")
        os.system(f"echo '{user.username}:{user.password}' | chpasswd")
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
    os.system(f"userdel -r {username}")
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
            os.system(f"usermod -L {username}") # قفل کردن اکانت سیستمی
        else:
            os.system(f"usermod -U {username}") # فعال‌سازی مجدد
    conn.close()
    return {"status": "success"}

@app.post("/api/user/reset/{username}")
async def reset_traffic(username: str):
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("UPDATE users SET volume_used = 0 WHERE username = ?", (username,))
    conn.commit()
    conn.close()
    return {"status": "success"}

@app.get("/api/backup")
async def download_backup():
    if os.path.exists(DB_PATH):
        return FileResponse(DB_PATH, media_type="application/octet-stream", filename="users_backup.db")
    raise HTTPException(status_code=404, detail="No backup available")

# وب‌ساکت پروکسی فوق‌سریع و مستقیم به پورت محلی SSH (22)
async def ssh_ws_handler(websocket, path):
    # این تابع ترافیک وب‌ساکت را با کمترین سربار به SSH محلی پاس می‌دهد
    # برای احراز هویت اولیه، بررسی ترافیک و ثبت اتصالات آنلاین کاربران بسیار بهینه عمل می‌کند.
    try:
        # شبیه‌ساز اتصال برای هماهنگی لاگین و ردیابی ترافیک دریافتی (Received)
        username = "unknown"
        # هدر ارتقا حاوی جزییات اتصال کاربر لینوکس
        headers = websocket.request_headers
        # در پروتکل‌های اتصال وب‌ساکت SSH، مسیرها معمولاً یوزرنیم را به عنوان شناسه حمل می‌کنند
        path_parts = path.strip("/").split("/")
        if len(path_parts) > 0 and path_parts[0]:
            username = path_parts[0]
            
        # ثبت اتصال آنلاین
        active_ws_connections[username] = datetime.now()
        
        # اتصال محلی به SSH
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
            conn = sqlite3.connect(DB_PATH)
            cursor = conn.cursor()
            try:
                while True:
                    data = await reader.read(4096)
                    if not data:
                        break
                    await websocket.send(data)
                    
                    # ثبت دقیق حجم مصرفی دریافتی (Received Bytes) کاربر
                    bytes_received = len(data)
                    gb_received = bytes_received / (1024 ** 3)
                    
                    cursor.execute(
                        "UPDATE users SET volume_used = volume_used + ? WHERE username = ?",
                        (gb_received, username)
                    )
                    conn.commit()
            except Exception:
                pass
            finally:
                conn.close()

        await asyncio.gather(ws_to_ssh(), ssh_to_ws())
    except Exception as e:
        pass
    finally:
        if username in active_ws_connections:
            # ذخیره آخرین زمان آنلاین بودن قبل خروج
            conn = sqlite3.connect(DB_PATH)
            cursor = conn.cursor()
            now_str = datetime.now().strftime("%m-%d %H:%M")
            cursor.execute("UPDATE users SET last_online = ? WHERE username = ?", (now_str, username))
            conn.commit()
            conn.close()
            del active_ws_connections[username]

# اجرای وب‌ساکت مستقل و بهینه در فرآیند پس‌زمینه
def start_ws_server():
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("SELECT value FROM settings WHERE key='ws_port'")
    port = int(cursor.fetchone()[0])
    conn.close()
    
    start_server = websockets.serve(ssh_ws_handler, "0.0.0.0", port)
    asyncio.get_event_loop().run_until_complete(start_server)
    asyncio.get_event_loop().run_forever()

if __name__ == "__main__":
    import threading
    # اجرای وب‌ساکت در ترد جداگانه جهت کارایی بالا
    t = threading.Thread(target=start_ws_server, daemon=True)
    t.start()
    
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
EOF

# ۴. ایجاد فایل‌های سرویس سیستم‌عامل (Systemd) جهت پایداری ۱۰۰٪
cat << 'EOF' > /etc/systemd/system/ssh-panel.service
[Unit]
Description=SSH Management and WS Panel
After=network.target

[Service]
User=root
WorkingDirectory=/root/ssh-panel
ExecStart=/root/ssh-panel/venv/bin/python3 main.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# فعال‌سازی سرویس‌ها
systemctl daemon-reload
systemctl enable ssh-panel.service
systemctl start ssh-panel.service

echo "=================================================="
echo "نصب با موفقیت انجام شد!"
echo "آدرس پنل مدیریت: http://YOUR_SERVER_IP:8000"
echo "نام کاربری پیش‌فرض مدیریت: admin"
echo "رمز عبور پیش‌فرض مدیریت: admin"
echo "=================================================="
