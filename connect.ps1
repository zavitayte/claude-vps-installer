<#
  Claude VPS — подключение с Windows: SSH-туннель + удалённый рабочий стол.

  Первый запуск (создаст ярлык "Claude VPS" на рабочем столе):
    powershell -ExecutionPolicy Bypass -File connect.ps1 -Ip 203.0.113.10 -CreateShortcut

  Дальше — двойной клик по ярлыку.
#>
param(
  [Parameter(Mandatory = $true)][string]$Ip,
  [string]$User = "claude",
  [int]$LocalPort = 3390,
  [switch]$CreateShortcut
)

$ErrorActionPreference = "Stop"

function Test-Port([int]$Port) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $async = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
    if ($async.AsyncWaitHandle.WaitOne(300)) { $client.EndConnect($async); return $true }
    return $false
  } catch { return $false } finally { $client.Close() }
}

if ($CreateShortcut) {
  $desktop = [Environment]::GetFolderPath("Desktop")
  $lnkPath = Join-Path $desktop "Claude VPS.lnk"
  $shell = New-Object -ComObject WScript.Shell
  $lnk = $shell.CreateShortcut($lnkPath)
  $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$PSCommandPath`" -Ip $Ip -User $User -LocalPort $LocalPort"
  $lnk.IconLocation = "$env:SystemRoot\System32\mstsc.exe,0"
  $lnk.Save()
  Write-Host "Ярлык создан: $lnkPath"
}

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
  throw "Не найден ssh. Включите 'Клиент OpenSSH' в Параметры -> Приложения -> Дополнительные компоненты."
}

# 1. Туннель: поднимаем, только если порт ещё не занят прошлым запуском
if (-not (Test-Port $LocalPort)) {
  Write-Host "Открываю SSH-туннель к $Ip. Введите пароль пользователя $User в новом окне и не закрывайте его."
  Start-Process ssh -ArgumentList @(
    "-N",
    "-o", "ServerAliveInterval=30",
    "-o", "ServerAliveCountMax=3",
    "-o", "ExitOnForwardFailure=yes",
    "-L", "${LocalPort}:127.0.0.1:3389",
    "$User@$Ip"
  )

  $deadline = (Get-Date).AddMinutes(3)
  while (-not (Test-Port $LocalPort)) {
    if ((Get-Date) -gt $deadline) { throw "Туннель не поднялся за 3 минуты. Проверьте IP и пароль." }
    Start-Sleep -Milliseconds 500
  }
}

# 2. RDP-файл: без вопросов про сертификат (соединение и так идёт через SSH)
$rdpPath = Join-Path $env:TEMP "claude-vps.rdp"
@"
full address:s:localhost:$LocalPort
username:s:$User
authentication level:i:0
prompt for credentials:i:0
screen mode id:i:2
redirectclipboard:i:1
"@ | Set-Content -Path $rdpPath -Encoding Unicode

Start-Process mstsc -ArgumentList "`"$rdpPath`""
