# Lugh Stack — Windows startup script
# Registered with Task Scheduler to run at logon.
# Starts the Docker Compose stack and Cloudflare tunnel.

$LOG   = "C:\ProgramData\Lugh\startup.log"
$PROJ  = "C:\Users\Automation\Desktop\phoneapp+apartment-16\phone-app"
$CF    = "C:\Users\Automation\Desktop\cloudflared.exe"

New-Item -ItemType Directory -Force "C:\ProgramData\Lugh" | Out-Null

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $msg" | Out-File -Append -Encoding utf8 $LOG
    Write-Host "$ts  $msg"
}

Log "=== Lugh startup ==="

# ── 1. Wait for Docker Desktop engine to be ready ─────────────────────────────
Log "Waiting for Docker Desktop..."
$retries = 0
while ($retries -lt 30) {
    try {
        & docker context use desktop-linux 2>$null | Out-Null
        $out = & docker info 2>$null
        if ($LASTEXITCODE -eq 0) { break }
    } catch {}
    $retries++
    Log "  Docker not ready yet ($retries/30)..."
    Start-Sleep -Seconds 10
}

if ($retries -eq 30) {
    Log "ERROR: Docker Desktop did not start in time. Giving up."
    exit 1
}

Log "Docker Desktop ready."

# ── 2. Start the stack ────────────────────────────────────────────────────────
Log "Starting Lugh stack..."
Push-Location $PROJ
$composeOut = & docker compose -f docker-compose.dev.yml up -d --remove-orphans 2>&1
$composeOut | ForEach-Object { Log "  $_" }

if ($LASTEXITCODE -ne 0) {
    Log "ERROR: docker compose failed. Checking if nginx needs a reload..."
}

# Give containers 15s to settle, then reload nginx so it re-resolves upstream IPs
Start-Sleep -Seconds 15
Log "Reloading nginx upstream DNS..."
& docker exec lugh_nginx nginx -s reload 2>&1 | ForEach-Object { Log "  $_" }
Pop-Location

Log "Stack started."

# ── 3. Start Cloudflare tunnel ────────────────────────────────────────────────
# If a named tunnel config exists, use it (permanent URL, runs as service instead).
# Otherwise fall back to a quick tunnel on port 8090.
$cfConfig = "$env:USERPROFILE\.cloudflared\config.yml"

if (Test-Path $cfConfig) {
    Log "Named tunnel config found — cloudflared service should already be running."
    # The named tunnel is managed by the 'cloudflared' Windows service, not this script.
} elseif (Test-Path $CF) {
    Log "Starting Cloudflare quick tunnel on port 8090..."
    $cfLog = "C:\ProgramData\Lugh\cloudflared.log"
    Start-Process -FilePath $CF `
        -ArgumentList "tunnel --url http://localhost:8090 --no-autoupdate" `
        -RedirectStandardOutput $cfLog `
        -RedirectStandardError  $cfLog `
        -WindowStyle Hidden

    # Wait up to 30s for the tunnel URL to appear in the log
    Log "Waiting for tunnel URL..."
    $waited = 0
    while ($waited -lt 30) {
        Start-Sleep -Seconds 2
        $waited += 2
        $content = Get-Content $cfLog -ErrorAction SilentlyContinue
        $urlLine = $content | Select-String "trycloudflare\.com"
        if ($urlLine) {
            $url = ($urlLine.Line -replace '.*?(https://[^\s]+trycloudflare\.com).*', '$1')
            Log "Tunnel URL: $url"
            Log "IMPORTANT: Update GitHub secret LUGH_SERVER_URL to: $url"
            # Write to a file so you can check it without reading logs
            $url | Out-File -Encoding utf8 "C:\ProgramData\Lugh\tunnel-url.txt"
            break
        }
    }
} else {
    Log "cloudflared.exe not found at $CF — skipping tunnel."
}

Log "=== Startup complete ==="
