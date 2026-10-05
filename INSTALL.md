# pyGate Installation

```bash
cd ~/pyGate/installer
sudo install -m 0755 ./m1 /usr/local/bin/m1
sudo m1 install
```

ติดตั้งครั้งแรกแล้ว คำสั่ง `m1` ใช้ได้ทุก path

| คำสั่ง | ทำอะไร |
|---|---|
| `sudo m1 install` | ติดตั้ง/อัปเดต library + Apache/PHP/MariaDB + front-end + service |
| `sudo m1 update` | clone ล่าสุดจาก `https://github.com/HWInnovationASF/m1_gate.git` (branch `main`) แล้วติดตั้ง — เปลี่ยนด้วย `REPO=`/`BRANCH=`, `REPO=` ว่างเพื่อใช้ชุดในเครื่อง |
| `m1 status` / `sudo m1 restart` / `m1 logs 200` | ดูแล `pygate.service` |

## รองรับ OS
Debian / Ubuntu / Raspberry Pi OS (apt), RHEL / Fedora / Rocky (dnf, yum), Arch (pacman)
— ตรวจ package manager อัตโนมัติ

> AppServ เป็นชุดสำหรับ Windows; บน Linux ตัวที่เทียบเท่าคือ Apache + PHP + MariaDB (WEB_STACK=lamp)
> ซึ่งติดตั้งให้เป็นค่าเริ่มต้น

## สิ่งที่ตัวติดตั้งทำ
1. ติดตั้ง package ระบบ (Python, Apache, PHP, MariaDB, rsync ฯลฯ)
2. คัดลอกแอปไป `/opt/pygate` (เก็บ `.env`, `gate_config.json`, `alarm_config.json`, `lid_list/`, `dlog/`, `logs/` เดิมไว้ และ backup ที่ `/var/backups/pygate`)
3. สร้าง venv `/opt/pygate/venv` แล้วลง/อัปเดต library จาก `requirements.txt`
4. สร้างฐานข้อมูล `pygate` + user (รหัสผ่านสุ่ม ถ้า `.env` ยังไม่มี `db_*`)
5. ลง front-end จาก `html/` หรือ `frontend/` ไปที่ `/var/www/html`
6. สร้างและเปิด `pygate.service` (Flask พอร์ต 8811)

## ตัวแปร
```bash
sudo env YES=1 WEB_STACK=none m1 install          # ไม่ลง Apache/PHP/MySQL
sudo env YES=1 FRONTEND_SRC=/path/to/dist m1 install
sudo env YES=1 PROXY=1 m1 install                 # Apache /pygate/ -> Flask :8811 (apt เท่านั้น)
```
`APP_DEST`, `WEB_DEST`, `RUN_USER`, `DB_NAME`, `DB_APP_USER`, `DB_APP_PASSWORD`, `SKIP_SERVICE=1`, `KEEP_BACKUPS`

## Windows (AppServ)

เปิด PowerShell แบบ **Run as administrator** ในโฟลเดอร์ `installer`:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 install
```

ครั้งแรกจะติดตั้งคำสั่ง `m1` (ที่ `C:\ProgramData\m1-installer`, เพิ่มใน PATH) ต่อจากนั้นใช้ `m1 install`, `m1 update`, `m1 status`, `m1 restart`, `m1 logs 200` ได้ (เปิดหน้าต่างใหม่หลังติดตั้งครั้งแรก)

- ตรวจ/ติดตั้ง Python 3.12 ผ่าน `winget` ถ้ายังไม่มี
- ใช้ AppServ ที่ `C:\AppServ` (ตั้ง `-AppServRoot` ได้) ถ้ายังไม่ได้ลง ให้ดาวน์โหลดจาก appserv.org แล้วระบุ `-AppServInstaller <path>` (ตัวติดตั้งต้องตั้งรหัส root MySQL เอง)
- front-end `html/` หรือ `frontend/` -> `C:\AppServ\www`
- แอปอยู่ที่ `C:\pyGate` (venv + Scheduled Task ชื่อ `pygate` เริ่มตอนบูต, log ที่ `logs\pygate.log`) และเปิด firewall พอร์ต 8811
- ตัวแปร: `-WebStack none`, `-FrontendSrc`, `-DbRootPassword`, `-DbName`, `-DbAppUser`, `-Yes` (หรือ env `YES=1`)

> หมายเหตุ: ส่วน GPIO ใน `app.py` ใช้ `/sys/class/gpio` ซึ่งมีเฉพาะ Linux/Raspberry Pi บน Windows ฟังก์ชันนั้นจะใช้ไม่ได้
