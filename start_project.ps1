param(
    [string]$Mode = "",
    [string]$IP = "",
    [switch]$SkipFlutter,
    [switch]$Debug
)

# PLC Project Launcher - local dev loop for Django + Flutter.
#
# Starts Django bound to 0.0.0.0:8000 (reachable from both the Android
# emulator and real devices on the LAN), creates/updates a "devtest" user +
# PLCDevice via bootstrap_dev_user so the app's login screen has something
# to sign in with, then launches Flutter. Does NOT modify any source files.

$projectRoot = Split-Path $MyInvocation.MyCommand.Path
$djangoPath  = $projectRoot
$flutterPath = "$projectRoot\flutter_application_plc"

function Write-Header {
    Write-Host ""
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "    PLC Project Launcher" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host ""
}

function Get-LocalIP {
    # Prefer an adapter that actually has a default gateway (real Wi-Fi/Ethernet),
    # skipping virtual adapters (Hyper-V, WSL, VPN, Docker NAT) that otherwise
    # tend to sort first and silently break "lan" mode.
    $candidate = Get-NetIPConfiguration |
        Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } |
        Select-Object -First 1
    if ($candidate) { return $candidate.IPv4Address.IPAddress }

    # Fallback: any non-loopback IPv4 address.
    return (Get-NetIPAddress | Where-Object {
        $_.AddressFamily -eq "IPv4" -and $_.InterfaceAlias -notlike "*Loopback*"
    } | Select-Object -First 1).IPAddress
}

function Get-PythonExe {
    $venvPython = "$djangoPath\.venv\Scripts\python.exe"
    if (Test-Path $venvPython) { return $venvPython }
    return "python"   # fall back to whatever's on PATH
}

function Check-Emulator {
    try {
        $devices = & flutter devices 2>$null | Select-String "emulator"
        return [bool]$devices
    } catch { return $false }
}

function Start-Django {
    param([int]$port = 8000)

    Write-Host "Starting Django on 0.0.0.0:$port (PLC_MOCK=True)..." -ForegroundColor Green
    Push-Location $djangoPath
    $pythonExe = Get-PythonExe

    & $pythonExe manage.py migrate 2>$null | Out-Null

    $env:PLC_MOCK = "True"
    if ($Debug) {
        Write-Host "Debug mode: running Django in foreground" -ForegroundColor Yellow
        & $pythonExe manage.py runserver "0.0.0.0:$port"
    } else {
        Start-Process -FilePath $pythonExe `
            -ArgumentList "manage.py", "runserver", "0.0.0.0:$port" `
            -NoNewWindow
    }
    Pop-Location
    return $true
}

function Bootstrap-DevUser {
    param([string]$clientIp)

    Write-Host "Bootstrapping dev user + PLCDevice (ip=$clientIp)..." -ForegroundColor Green
    Push-Location $djangoPath
    $pythonExe = Get-PythonExe
    & $pythonExe manage.py bootstrap_dev_user --ip $clientIp
    Pop-Location
}

function Start-Flutter {
    Write-Host "Starting Flutter app..." -ForegroundColor Green
    Push-Location $flutterPath
    if ($Debug) {
        & flutter run --debug
    } else {
        & flutter run
    }
    Pop-Location
}

# --- Main --------------------------------------------------------------

Write-Header

$emulatorRunning = Check-Emulator
$localIP         = Get-LocalIP

Write-Host "System Detection:" -ForegroundColor Yellow
Write-Host "  Emulator running: $emulatorRunning"
Write-Host "  Local IP:         $localIP"
Write-Host ""

if ($Mode -eq "") {
    Write-Host "Select mode:" -ForegroundColor Yellow
    Write-Host "  1. Local (Android Emulator)"
    Write-Host "  2. LAN (real device on same WiFi)"
    Write-Host "  3. Custom IP"
    $choice = Read-Host "Enter choice (1-3)"
    switch ($choice) {
        "1" { $Mode = "local" }
        "2" { $Mode = "lan" }
        "3" { $Mode = "custom" }
        default { Write-Host "Invalid choice" -ForegroundColor Red; exit 1 }
    }
}

# clientIp is what the PHONE/EMULATOR uses to reach this PC - distinct from
# the bind address, which is always 0.0.0.0 so every mode can be served by
# one Django process.
switch ($Mode) {
    "local" {
        $clientIp = "10.0.2.2"   # Android emulator's alias for the host machine
        Write-Host "Emulator client endpoint: http://${clientIp}:8000" -ForegroundColor Green
    }
    "lan" {
        if (-not $localIP) {
            Write-Host "Could not auto-detect a LAN IP - pass -IP explicitly." -ForegroundColor Red
            exit 1
        }
        $clientIp = $localIP
        Write-Host "LAN client endpoint: http://${clientIp}:8000" -ForegroundColor Green
        Write-Host "Make sure your phone is on the same WiFi network." -ForegroundColor Yellow
    }
    "custom" {
        if ($IP -eq "") { $IP = Read-Host "Enter the IP your device should use" }
        $clientIp = $IP
        Write-Host "Custom client endpoint: http://${clientIp}:8000" -ForegroundColor Green
    }
    default {
        Write-Host "Unknown mode '$Mode'" -ForegroundColor Red
        exit 1
    }
}

if (-not (Start-Django)) {
    Write-Host "Failed to start Django" -ForegroundColor Red
    exit 1
}

Start-Sleep -Seconds 3
Bootstrap-DevUser -clientIp $clientIp

Write-Host ""
Write-Host "Type these into the app's login screen:" -ForegroundColor Cyan
Write-Host "  Server address: http://${clientIp}:8000"
Write-Host "  Username:       devtest"
Write-Host "  Password:       DevTest12345"
Write-Host ""

if ($SkipFlutter) {
    Write-Host "Django started. Flutter skipped." -ForegroundColor Green
    Read-Host "Press Enter to exit"
} else {
    if ($Mode -eq "local" -and -not $emulatorRunning) {
        Write-Host "No emulator detected - launch one from Android Studio or 'flutter emulators --launch <id>' first." -ForegroundColor Yellow
    }
    Start-Flutter
}
