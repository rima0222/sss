cat <<'EOF' > /var/lib/ssh-panel/templates/index.html
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>کنترل سنتر اختصاصی</title>
    <link rel="stylesheet" href="/static/app.css">
    <style>
        .user-pass-container { display: flex; flex-direction: column; gap: 4px; font-family: monospace; font-size: 0.85rem; text-align: right; }
        .user-text { color: #fff; font-weight: bold; }
        .pass-text { color: #a5b1c2; }
        .action-btn { padding: 6px 12px; border-radius: 6px; border: none; cursor: pointer; font-weight: bold; font-size: 0.8rem; transition: all 0.2s; margin: 2px; }
        .btn-pause { background-color: #f7b731; color: #000; }
        .btn-resume { background-color: #2bcbba; color: #fff; }
        .btn-danger { background-color: #ff6b6b; color: #fff; }
        .btn-warning { background-color: #fa8231; color: #fff; }
        .btn-blue { background-color: #3867d6; color: #fff; }
        
        /* رنگ بنفش برای وضعیت فعال */
        .active-status { background-color: rgba(136, 84, 208, 0.2) !important; color: #a55eea !important; border: 1px solid #8854d0 !important; }
        
        /* انیمیشن پالس سبز برای آنلاین */
        .online-pulse {
            background-color: rgba(38, 222, 129, 0.2) !important;
            color: #26de81 !important;
            border: 1px solid #26de81 !important;
            position: relative;
            animation: pulse-green 2s infinite;
        }
        @keyframes pulse-green {
            0% { box-shadow: 0 0 0 0 rgba(38, 222, 129, 0.4); }
            70% { box-shadow: 0 0 0 10px rgba(38, 222, 129, 0); }
            100% { box-shadow: 0 0 0 0 rgba(38, 222, 129, 0); }
        }

        .modal { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.7); justify-content: center; align-items: center; z-index: 1000; }
        .modal-content { background: #1e272e; padding: 25px; border-radius: 12px; width: 350px; border: 1px solid #3867d6; }
    </style>
</head>
<body>
    <div class="grid-background"></div>
    <div class="container">
        <header class="header-section">
            <div class="header-left">
                <a href="/logout" class="btn btn-logout">خروج</a>
                <a href="/api/backup/export" class="btn btn-backup">دانلود بکاپ</a>
            </div>
            <div class="header-right">
                <div class="brand-info">
                    <span class="sub-brand">MANAGEMENT</span>
                    <h1 class="brand-title">کنترل پنل مدیریت کاربران</h1>
                </div>
                <div class="avatar-icon">CP</div>
            </div>
        </header>

        <!-- آمارها -->
        <div class="status-grid">
            <div class="status-card"><span class="status-label">RAM</span><span class="status-value" id="live-ram">{{ ram_usage }}</span></div>
            <div class="status-card"><span class="status-label">مصرف کل</span><span class="status-value">GB {{ total_used }}</span></div>
            <div class="status-card"><span class="status-label">حجم کل</span><span class="status-value">GB {{ total_allowed_vol }}</span></div>
            <div class="status-card"><span class="status-label">آنلاین</span><span class="status-value" id="live-online">{{ online_count }}</span></div>
            <div class="status-card"><span class="status-label">فعال</span><span class="status-value">{{ active_count }}</span></div>
            <div class="status-card"><span class="status-label">کل کاربران</span><span class="status-value">{{ total_users_count }}</span></div>
        </div>

        <div class="main-layout">
            <div class="sidebar-column">
                <div class="card panel-card">
                    <div class="card-header">
                        <span class="tag tag-purple">PORT</span>
                        <span class="card-title">تنظیمات پورت و مدیریت</span>
                    </div>
                    <form id="settingsForm">
                        <div class="form-group">
                            <label class="field-label">نام کاربری مدیر</label>
                            <input type="text" id="adminUser" value="{{ admin_user }}" required>
                        </div>
                        <div class="form-group">
                            <label class="field-label">رمز عبور جدید مدیر</label>
                            <input type="password" id="adminPass" placeholder="خالی بگذارید تا تغییر نکند">
                        </div>
                        <div class="form-group">
                            <label class="field-label">پورت وب‌ساکت (SSHWS)</label>
                            <input type="number" id="sshWsPort" value="{{ ssh_ws_port }}" required>
                        </div>
                        <button type="submit" class="btn btn-blue btn-block">ذخیره تنظیمات</button>
                    </form>
                </div>

                <!-- بخش بازیابی بکاپ -->
                <div class="card panel-card" style="margin-top: 20px;">
                    <div class="card-header">
                        <span class="tag tag-purple">JSON</span>
                        <span class="card-title">بازیابی اطلاعات</span>
                    </div>
                    <div class="backup-area">
                        <div class="file-drop-area" onclick="document.getElementById('backupFile').click()">
                            <span id="file-name-label">انتخاب فایل بکاپ</span>
                            <input type="file" id="backupFile" accept=".json" style="display: none;" onchange="updateFileName(this)">
                        </div>
                        <button onclick="importBackup()" class="btn btn-blue btn-block" style="margin-top: 15px;">بازیابی بکاپ</button>
                    </div>
                </div>
            </div>

            <div class="content-column">
                <div class="card panel-card">
                    <div class="card-header">
                        <span class="tag tag-blue">USER</span>
                        <span class="card-title">ساخت کاربر جدید</span>
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
                                <label class="field-label">حجم (GB)</label>
                                <input type="number" step="0.1" id="addVolume" value="10" required>
                            </div>
                            <div class="form-group">
                                <label class="field-label">زمان (روز)</label>
                                <input type="number" step="1" id="addTime" value="30" required>
                            </div>
                        </div>
                        <button type="submit" class="btn btn-blue btn-block" style="margin-top: 15px;">ساخت کاربر</button>
                    </form>
                </div>
            </div>
        </div>

        <!-- جدول مدیریت کاربران -->
        <div class="card panel-card" style="margin-top: 25px;">
            <div class="users-header">
                <span class="card-title">مدیریت کاربران</span>
                <div class="search-box">
                    <input type="text" id="userSearch" placeholder="جستجو نام کاربری..." onkeyup="searchUsers()">
                </div>
            </div>

            <div class="table-responsive">
                <table>
                    <thead>
                        <tr>
                            <th style="text-align: right; width: 180px;">اطلاعات اتصال (User/Pass)</th>
                            <th style="text-align: center;">وضعیت حساب</th>
                            <th style="text-align: center;">اتصال زنده</th>
                            <th style="text-align: center; width: 180px;">مصرف دیتا</th>
                            <th style="text-align: center;">زمان باقی‌مانده</th>
                            <th style="text-align: left; padding-left: 20px;">عملیات</th>
                        </tr>
                    </thead>
                    <tbody id="usersTableBody">
                        {% for user in users %}
                        <tr class="user-row" id="user-row-{{ user.username }}">
                            <td style="text-align: right; display: flex; align-items: center; gap: 10px; height: 55px;">
                                <div class="user-avatar-blue">{{ user.username[0]|upper }}</div>
                                <div class="user-pass-container">
                                    <span class="user-text">{{ user.username }}</span>
                                    <span class="pass-text">رمز: {{ user.password }}</span>
                                </div>
                            </td>
                            <td style="text-align: center;">
                                {% if user.status == 'active' %}
                                    <span class="status-indicator active-status">فعال</span>
                                {% else %}
                                    <span class="status-indicator offline" style="color: #ff7675; border-color: #ff7675;">Pause</span>
                                {% endif %}
                            </td>
                            <td style="text-align: center;" class="user-online-status">
                                {% if user.is_online %}
                                    <span class="status-indicator online-pulse">آنلاین</span>
                                {% else %}
                                    <span class="status-indicator offline">آفلاین</span>
                                {% endif %}
                            </td>
                            <td style="text-align: center;">
                                <div class="traffic-container" style="direction: ltr;">
                                    <span class="traffic-text" style="color: #a5b1c2; font-size: 0.8rem;">
                                        {{ "%.2f"|format(user.used_download) }} / {{ "%.2f"|format(user.total_volume) }} GB
                                    </span>
                                    <div class="progress-bar" style="margin-top: 4px;">
                                        <div class="progress-fill" style="width: {{ (user.used_download / user.total_volume * 100)|int if user.total_volume > 0 else 0 }}%;"></div>
                                    </div>
                                </div>
                            </td>
                            <td style="text-align: center;">
                                <span class="time-badge">{{ user.readable_time }}</span>
                            </td>
                            <td style="text-align: left; white-space: nowrap; padding-left: 20px;">
                                <button onclick="deleteUser('{{ user.username }}')" class="action-btn btn-danger">حذف</button>
                                <button onclick="resetUser('{{ user.username }}')" class="action-btn btn-warning">ریست</button>
                                <button onclick="openEditModal('{{ user.username }}', '{{ user.password }}', '{{ user.total_volume }}', '{{ user.remaining_time }}')" class="action-btn btn-blue">ویرایش</button>
                                {% if user.status == 'active' %}
                                    <button onclick="toggleUserStatus('{{ user.username }}', 'pause')" class="action-btn btn-pause">Pause</button>
                                {% else %}
                                    <button onclick="toggleUserStatus('{{ user.username }}', 'resume')" class="action-btn btn-resume">Resume</button>
                                {% endif %}
                            </td>
                        </tr>
                        {% endfor %}
                    </tbody>
                </table>
            </div>
        </div>
    </div>

    <!-- مودال ادیت -->
    <div id="editModal" class="modal">
        <div class="modal-content">
            <h3 style="color: #fff; margin-bottom: 15px; text-align: center;">ویرایش اطلاعات کاربر</h3>
            <form id="editUserForm">
                <input type="hidden" id="editUsername">
                <div class="form-group" style="margin-bottom: 12px;">
                    <label class="field-label" style="color: #a5b1c2;">رمز عبور جدید</label>
                    <input type="text" id="editPassword" required style="width: 100%; padding: 8px; background: #2f3640; border: none; color: #fff; border-radius: 6px;">
                </div>
                <div class="form-group" style="margin-bottom: 12px;">
                    <label class="field-label" style="color: #a5b1c2;">حجم کل (GB)</label>
                    <input type="number" step="0.1" id="editVolume" required style="width: 100%; padding: 8px; background: #2f3640; border: none; color: #fff; border-radius: 6px;">
                </div>
                <div class="form-group" style="margin-bottom: 20px;">
                    <label class="field-label" style="color: #a5b1c2;">زمان باقی‌مانده (روز)</label>
                    <input type="number" id="editTime" required style="width: 100%; padding: 8px; background: #2f3640; border: none; color: #fff; border-radius: 6px;">
                </div>
                <div style="display: flex; gap: 10px;">
                    <button type="submit" class="btn btn-blue" style="flex: 1; padding: 10px;">ذخیره</button>
                    <button type="button" onclick="closeEditModal()" class="action-btn btn-danger" style="flex: 1; padding: 10px;">انصراف</button>
                </div>
            </form>
        </div>
    </div>

    <script src="/static/app.js"></script>
    <script>
        function updateFileName(i) { document.getElementById('file-name-label').innerText = i.files[0] ? i.files[0].name : "انتخاب فایل بکاپ"; }
        function openEditModal(u, p, v, t) {
            document.getElementById('editUsername').value = u;
            document.getElementById('editPassword').value = p;
            document.getElementById('editVolume').value = v;
            document.getElementById('editTime').value = Math.round(t / 86400);
            document.getElementById('editModal').style.display = 'flex';
        }
        function closeEditModal() { document.getElementById('editModal').style.display = 'none'; }

        document.getElementById('editUserForm').addEventListener('submit', function(e) {
            e.preventDefault();
            fetch('/api/user/edit', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    username: document.getElementById('editUsername').value,
                    password: document.getElementById('editPassword').value,
                    total_volume: parseFloat(document.getElementById('editVolume').value),
                    remaining_time: parseInt(document.getElementById('editTime').value) * 86400
                })
            }).then(r => r.json()).then(res => { if(res.success) location.reload(); else alert('خطا در ذخیره‌سازی'); });
        });

        function toggleUserStatus(username, action) {
            fetch(`/api/user/${action}`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ username })
            }).then(r => r.json()).then(res => { if(res.success) location.reload(); });
        }

        const eventSource = new EventSource("/api/live-stream");
        eventSource.onmessage = function(event) {
            const data = JSON.parse(event.data);
            document.getElementById("live-ram").innerText = data.ram;
            document.getElementById("live-online").innerText = data.online_count;
            const rows = document.querySelectorAll("#usersTableBody tr");
            rows.forEach(row => {
                const uSpan = row.querySelector(".user-text");
                if (uSpan) {
                    const username = uSpan.textContent.trim();
                    const statusTd = row.querySelector(".user-online-status");
                    if (data.online_users.includes(username)) {
                        statusTd.innerHTML = '<span class="status-indicator online-pulse">آنلاین</span>';
                    } else {
                        statusTd.innerHTML = '<span class="status-indicator offline">آفلاین</span>';
                    }
                }
            });
        };
    </script>
</body>
</html>
EOF

# بازنویسی مسیرهای API بک‌اند
cat <<'EOF' > /var/lib/ssh-panel/app/routes.py
from flask import Blueprint, render_template, request, jsonify, session, redirect, url_for
import subprocess
from app.db import get_db_connection

bp = Blueprint('routes', __name__)

@bp.route('/api/user/edit', methods=['POST'])
def edit_user():
    data = request.json
    u, p, vol, r_time = data['username'], data['password'], data['total_volume'], data['remaining_time']
    conn = get_db_connection()
    conn.execute("UPDATE users SET password=?, total_volume=?, remaining_time=? WHERE username=?", (p, vol, r_time, u))
    conn.commit()
    conn.close()
    subprocess.run(f"echo '{u}:{p}' | chpasswd", shell=True)
    return jsonify({"success": True})

@bp.route('/api/user/pause', methods=['POST'])
def pause_user():
    u = request.json['username']
    conn = get_db_connection()
    conn.execute("UPDATE users SET status='paused' WHERE username=?", (u,))
    conn.commit()
    conn.close()
    subprocess.run(f"usermod -L {u}", shell=True)
    subprocess.run(f"pkill -u {u}", shell=True)
    return jsonify({"success": True})

@bp.route('/api/user/resume', methods=['POST'])
def resume_user():
    u = request.json['username']
    conn = get_db_connection()
    conn.execute("UPDATE users SET status='active' WHERE username=?", (u,))
    conn.commit()
    conn.close()
    subprocess.run(f"usermod -U {u}", shell=True)
    return jsonify({"success": True})
EOF

# ری‌استارت سرویس‌ها بدون متوقف کردن کلی sshd
systemctl daemon-reload
systemctl restart ssh-pro-panel
systemctl restart ssh-pro-worker

echo "=== تغییرات به صورت کاملاً ایمن اعمال شد. اتصال ترمینوس شما قطع نخواهد شد! ==="
