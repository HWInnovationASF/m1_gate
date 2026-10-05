<#
 pyGate installer/updater for Windows (AppServ = Apache + PHP + MySQL)
 Usage (Administrator PowerShell):  m1 install | update | status | restart | logs [N] | version
 หรือ: powershell -ExecutionPolicy Bypass -File install.ps1 install
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = 'help',
  [Parameter(Position = 1)][int]$Lines = 100,
  [string]$SourceDir,
  [string]$AppDest      = $(if ($env:APP_DEST)  { $env:APP_DEST }  else { 'C:\pyGate' }),
  [string]$AppServRoot  = $(if ($env:APPSERV_ROOT) { $env:APPSERV_ROOT } else { 'C:\AppServ' }),
  [string]$WebDest,                                  # ค่าเริ่มต้น: <AppServ>\www
  [string]$FrontendSrc  = $env:FRONTEND_SRC,
  [string]$Repo         = $(if ($null -ne $env:REPO) { $env:REPO } else { 'https://github.com/HWInnovationASF/m1_gate.git' }),
  [string]$Branch       = $(if ($env:BRANCH) { $env:BRANCH } else { 'main' }),
  [ValidateSet('appserv', 'none')][string]$WebStack = $(if ($env:WEB_STACK) { $env:WEB_STACK } else { 'appserv' }),
  [string]$AppServInstaller = $env:APPSERV_INSTALLER, # path ของ appserv-win32-*.exe (ถ้ายังไม่ได้ลง)
  [string]$DbRootPassword = $env:DB_ROOT_PASSWORD,
  [string]$DbName       = $(if ($env:DB_NAME) { $env:DB_NAME } else { 'pygate' }),
  [string]$DbAppUser    = $(if ($env:DB_APP_USER) { $env:DB_APP_USER } else { 'pygate' }),
  [string]$DbAppPassword = $env:DB_APP_PASSWORD,
  [int]$AppPort         = $(if ($env:APP_PORT) { [int]$env:APP_PORT } else { 8811 }),
  [switch]$Yes          = ($env:YES -eq '1'),
  [switch]$SkipService  = ($env:SKIP_SERVICE -eq '1')
)
$ErrorActionPreference = 'Stop'
$TaskName   = 'pygate'
$M1Home     = Join-Path $env:ProgramData 'm1-installer'
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $WebDest) { $WebDest = Join-Path $AppServRoot 'www' }

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Find-Python {
  foreach ($c in 'py', 'python') { $p = Get-Command $c -ErrorAction SilentlyContinue; if ($p) { return $p.Source } }
  return $null
}

switch ($Command) {
  'version' { 'm1 installer 20261005 (windows)'; return }
  'status'  { Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo | Format-List TaskName,LastRunTime,LastTaskResult
              Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName,State | Format-Table; return }
  'restart' { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
              Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -like "*$AppDest*app.py*" } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
              Start-ScheduledTask -TaskName $TaskName; Start-Sleep 2
              (Get-ScheduledTask -TaskName $TaskName).State; return }
  'logs'    { Get-Content (Join-Path $AppDest 'logs\pygate.log') -Tail $Lines; return }
  'help'    { @'
Usage: m1 <command>
  install    ติดตั้ง/อัปเดต Python libs + AppServ(Apache/PHP/MySQL) + front-end + startup task
  update     clone ล่าสุดจาก GitHub (m1_gate) แล้วติดตั้ง (ไม่ทับ config/log); REPO= ว่าง = ใช้ชุดในเครื่อง
  status | restart | logs [N] | version
ตัวแปร (env หรือ -Parameter): YES=1, WEB_STACK=appserv|none, FRONTEND_SRC, APP_DEST (C:\pyGate),
  APPSERV_ROOT (C:\AppServ), APPSERV_INSTALLER, DB_ROOT_PASSWORD, DB_NAME, DB_APP_USER, DB_APP_PASSWORD
'@; return }
  { $_ -in 'install', 'update' } { }
  default   { Write-Error "ไม่รู้จักคำสั่ง: $Command (ดู: m1 help)"; return }
}

if (-not (Test-Admin)) { throw 'กรุณารันใน PowerShell แบบ Run as administrator' }

# ---- update: clone ล่าสุดจาก GitHub (Repo ว่าง = ใช้ชุดในเครื่อง) ----
if ($Command -eq 'update' -and -not $SourceDir -and $Repo) {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'ไม่พบ git — ติดตั้ง git ก่อน' }
    winget install -e --id Git.Git --silent --accept-package-agreements --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
  }
  $SourceDir = Join-Path $env:TEMP "m1-update-$(Get-Date -Format yyyyMMddHHmmss)"
  Step "ดาวน์โหลดเวอร์ชันล่าสุด: $Repo"
  git clone --depth 1 --branch $Branch $Repo $SourceDir
  if ($LASTEXITCODE) { throw 'git clone ล้มเหลว' }
  $Yes = [switch]::Present
}
# ---- หา source (โฟลเดอร์ที่มี app.py) ----
if (-not $SourceDir) {
  foreach ($c in (Join-Path $ScriptDir '..'), (Join-Path $ScriptDir 'source')) {
    if (Test-Path (Join-Path $c 'app.py')) { $SourceDir = $c; break }
  }
}
if (-not $SourceDir -or -not (Test-Path (Join-Path $SourceDir 'app.py'))) { throw 'ไม่พบ app.py (ระบุด้วย -SourceDir)' }
$SourceDir = (Resolve-Path $SourceDir).Path

Write-Host '==================================================='
Write-Host " pyGate installer (Windows)"
Write-Host " Source : $SourceDir"
Write-Host " App    : $AppDest"
Write-Host " Web    : $WebStack -> $WebDest"
Write-Host '==================================================='
if (-not $Yes -and $Command -eq 'install') {
  if ((Read-Host 'ดำเนินการติดตั้ง/อัปเดตหรือไม่? พิมพ์ yes') -ne 'yes') { 'ยกเลิก'; return }
}

# ---- 1) Python ----
Step 'ตรวจ Python'
$py = Find-Python
if (-not $py) {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'ไม่พบ Python และไม่มี winget — ติดตั้ง Python 3.10+ ก่อน' }
  winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
  $py = Find-Python
  if (-not $py) { throw 'ติดตั้ง Python แล้วแต่หา python ไม่เจอ — เปิด PowerShell ใหม่แล้วรันอีกครั้ง' }
}

# ---- 2) AppServ ----
$mysqlExe = Join-Path $AppServRoot 'MySQL\bin\mysql.exe'
if ($WebStack -eq 'appserv') {
  if (-not (Test-Path $AppServRoot)) {
    if ($AppServInstaller -and (Test-Path $AppServInstaller)) {
      Step 'เปิดตัวติดตั้ง AppServ (ตั้งรหัส root MySQL ในหน้าต่างติดตั้ง แล้วรัน m1 install อีกครั้ง)'
      Start-Process $AppServInstaller -Wait
    }
    if (-not (Test-Path $AppServRoot)) {
      Write-Warning "ไม่พบ AppServ ที่ $AppServRoot — ดาวน์โหลดจาก https://www.appserv.org แล้วระบุ -AppServInstaller <path> หรือติดตั้งเอง; ข้ามขั้น web stack"
      $WebStack = 'none'
    }
  }
}

# ---- 3) backup + คัดลอกแอป ----
$preserve = '.env', 'gate_config.json', 'alarm_config.json', 'gate_config_cases.json', 'lid_list', 'dlog', 'logs'
$backup = Join-Path 'C:\ProgramData\pygate-backups' (Get-Date -Format 'yyyyMMdd_HHmmss')
New-Item -ItemType Directory -Force $backup, $AppDest | Out-Null
foreach ($i in $preserve) { $p = Join-Path $AppDest $i; if (Test-Path $p) { Copy-Item $p $backup -Recurse -Force } }
Step "Backup config: $backup"

Step "คัดลอกแอป -> $AppDest (เก็บ config/log เดิมไว้)"
$xd = '.git', 'installer', '__pycache__', 'venv', 'presence_preview', 'backup_*', 'lid_list', 'dlog', 'logs'
$xf = '*.bak*', '*.pre_*', '*.test_damaged', '*.lock', '*.pyc', '.env', 'gate_config.json', 'gate_config.json.prev', 'alarm_config.json'
robocopy $SourceDir $AppDest /E /XD $xd /XF $xf /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy ล้มเหลว (code $LASTEXITCODE)" }
foreach ($f in '.env', 'gate_config.json', 'alarm_config.json') {   # seed เฉพาะเครื่องใหม่
  $s = Join-Path $SourceDir $f; $d = Join-Path $AppDest $f
  if ((Test-Path $s) -and -not (Test-Path $d)) { Copy-Item $s $d }
}
foreach ($d in 'logs', 'dlog', 'lid_list') { New-Item -ItemType Directory -Force (Join-Path $AppDest $d) | Out-Null }

# ---- 4) venv + libraries ----
Step 'ติดตั้ง/อัปเดต Python libraries (venv)'
$venvPy = Join-Path $AppDest 'venv\Scripts\python.exe'
if (-not (Test-Path $venvPy)) { & $py -m venv (Join-Path $AppDest 'venv'); if ($LASTEXITCODE) { throw 'สร้าง venv ไม่สำเร็จ' } }
& $venvPy -m pip --disable-pip-version-check install --upgrade pip | Out-Null
$req = Join-Path $SourceDir 'requirements.txt'
if (Test-Path $req) {
  $clean = Join-Path $AppDest 'requirements.txt'
  Get-Content $req | ForEach-Object { ($_ -replace '\s*--break-system-packages', '').Trim() } |
    Where-Object { $_ -and $_ -notmatch '^(pip install|#)' } | Set-Content $clean -Encoding ASCII
  & $venvPy -m pip install -U -r $clean
} else {
  & $venvPy -m pip install -U Flask flask-mqtt flask-socketio PyMySQL requests python-dotenv paho-mqtt
}
if ($LASTEXITCODE) { throw 'pip install ล้มเหลว' }

# ---- 5) DB + front-end ----
if ($WebStack -eq 'appserv') {
  if (-not (Test-Path $mysqlExe)) { Write-Warning "ไม่พบ $mysqlExe — ข้ามการสร้าง DB" }
  else {
    function Get-EnvValue($k) { $l = Select-String -Path (Join-Path $AppDest '.env') -Pattern "^$k=(.*)$" -ErrorAction SilentlyContinue | Select-Object -First 1; if ($l) { $l.Matches[0].Groups[1].Value } }
    if (-not $DbAppPassword) { $DbAppPassword = Get-EnvValue 'db_pass' }
    if (-not $DbAppPassword) { $DbAppPassword = -join ((48..57) + (97..122) | Get-Random -Count 20 | ForEach-Object { [char]$_ }) }
    if ($DbAppPassword -notmatch '^[A-Za-z0-9@._%+=:-]+$' -or $DbName -notmatch '^\w+$' -or $DbAppUser -notmatch '^\w+$') { throw 'DB name/user/password มีอักขระที่ไม่รองรับ' }
    if (-not $DbRootPassword) { $sec = Read-Host 'รหัส root ของ MySQL (AppServ)' -AsSecureString
      $DbRootPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)) }
    $sql = "CREATE DATABASE IF NOT EXISTS ``$DbName`` CHARACTER SET utf8mb4; " +
           "CREATE USER IF NOT EXISTS '$DbAppUser'@'localhost' IDENTIFIED BY '$DbAppPassword'; " +
           "GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbAppUser'@'localhost'; FLUSH PRIVILEGES;"
    $env:MYSQL_PWD = $DbRootPassword
    try { & $mysqlExe -uroot -e $sql; if ($LASTEXITCODE) { throw 'สร้าง DB ไม่สำเร็จ (รหัส root ถูกต้องหรือไม่?)' } }
    finally { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue }
    Step "DB พร้อม: $DbName (user $DbAppUser)"
    $envFile = Join-Path $AppDest '.env'; if (-not (Test-Path $envFile)) { New-Item $envFile -ItemType File | Out-Null }
    foreach ($kv in @{ db_host = 'localhost'; db_user = $DbAppUser; db_pass = $DbAppPassword }.GetEnumerator()) {
      if (-not (Select-String -Path $envFile -Pattern "^$($kv.Key)=" -Quiet)) { Add-Content $envFile "$($kv.Key)=$($kv.Value)" }
    }
  }

  if (-not $FrontendSrc) { foreach ($c in 'html', 'frontend') { $p = Join-Path $SourceDir $c; if (Test-Path $p) { $FrontendSrc = $p; break } } }
  if ($FrontendSrc -and (Test-Path $FrontendSrc)) {
    Step "ลง front-end: $FrontendSrc -> $WebDest"
    New-Item -ItemType Directory -Force $WebDest | Out-Null
    robocopy $FrontendSrc $WebDest /E /XD config data 'log*' /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy front-end ล้มเหลว (code $LASTEXITCODE)" }
  } else { Write-Host '-- ไม่พบโฟลเดอร์ front-end (html/ หรือ frontend/) — ข้าม (ระบุด้วย -FrontendSrc)' }

  $svc = Get-Service | Where-Object { $_.Name -match '^(Apache|httpd)' -or $_.DisplayName -match 'Apache' } | Select-Object -First 1
  if ($svc) { Restart-Service $svc.Name -ErrorAction SilentlyContinue }
}

# ---- 6) ติดตั้งคำสั่ง m1 ----
Step 'ติดตั้งคำสั่ง m1'
New-Item -ItemType Directory -Force $M1Home | Out-Null
if ((Resolve-Path $ScriptDir).Path -ne (Resolve-Path $M1Home).Path) {
  Copy-Item (Join-Path $ScriptDir 'install.ps1'), (Join-Path $ScriptDir 'm1.cmd') $M1Home -Force
  robocopy $SourceDir (Join-Path $M1Home 'source') /MIR /XD .git installer venv __pycache__ /XF .env /NFL /NDL /NJH /NJS /NP | Out-Null
}
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if (($machinePath -split ';') -notcontains $M1Home) { [Environment]::SetEnvironmentVariable('Path', "$machinePath;$M1Home", 'Machine') }

# ---- 7) startup task (ทำงานตอนบูต, restart เมื่อล้ม) ----
if (-not $SkipService) {
  Step "ตั้งค่า Scheduled Task '$TaskName'"
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -like "*$AppDest*app.py*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  $log = Join-Path $AppDest 'logs\pygate.log'
  $action   = New-ScheduledTaskAction -Execute 'cmd.exe' -WorkingDirectory $AppDest `
              -Argument "/c `"`"$venvPy`" app.py >> `"$log`" 2>&1`""
  $trigger  = New-ScheduledTaskTrigger -AtStartup
  $settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
              -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskName
  Start-Sleep 3
  if ((Get-ScheduledTask -TaskName $TaskName).State -ne 'Running') { Write-Warning "task ไม่ได้อยู่ในสถานะ Running — ดู: m1 logs" }
  if (-not (Get-NetFirewallRule -DisplayName 'pyGate' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'pyGate' -Direction Inbound -Protocol TCP -LocalPort $AppPort -Action Allow | Out-Null
  }
}

Write-Host '==================================================='
Write-Host 'ติดตั้ง pyGate สำเร็จ'
Write-Host "App    : $AppDest  (http://<ip>:$AppPort)"
if ($WebStack -eq 'appserv') { Write-Host "Web    : $WebDest  (AppServ)" }
Write-Host "Backup : $backup"
Write-Host 'ตรวจสอบ: m1 status | m1 logs'
Write-Host '==================================================='
