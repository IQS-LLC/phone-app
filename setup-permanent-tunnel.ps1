# Lugh — One-time setup for a permanent Cloudflare named tunnel
#
# Prerequisites:
#   1. A free Cloudflare account at https://dash.cloudflare.com/sign-up
#   2. Your domain (e.g. hzortech.com) added to Cloudflare as the DNS provider
#      (Cloudflare > Add a Site > change nameservers at your registrar)
#
# Run this script ONCE. After it completes the tunnel URL never changes and
# cloudflared runs as a Windows service that survives reboots automatically.
#
# Usage:
#   .\setup-permanent-tunnel.ps1 -Domain "hzortech.com" -Subdomain "lugh"
#
# Result:
#   Permanent URL: https://lugh.hzortech.com
#   Update GitHub secret: gh secret set LUGH_SERVER_URL --body "https://lugh.hzortech.com" --repo IQS-LLC/phone-app
#   Then push a commit to rebuild the apps with the permanent URL baked in.

param(
    [Parameter(Mandatory)][string]$Domain,
    [Parameter(Mandatory)][string]$Subdomain
)

$CF       = "C:\Users\Automation\Desktop\cloudflared.exe"
$HOSTNAME = "$Subdomain.$Domain"
$TUNNEL   = "lugh-backend"
$PORT     = 8090

Write-Host "`n=== Lugh Permanent Tunnel Setup ===" -ForegroundColor Cyan
Write-Host "Target URL: https://$HOSTNAME"
Write-Host "Tunnel name: $TUNNEL"
Write-Host ""

if (-not (Test-Path $CF)) {
    Write-Error "cloudflared.exe not found at $CF"
    exit 1
}

# Step 1 — Authenticate with Cloudflare (opens browser, select your zone)
Write-Host "Step 1: Opening browser for Cloudflare authentication..." -ForegroundColor Yellow
Write-Host "Select '$Domain' in the browser when prompted."
& $CF login
if ($LASTEXITCODE -ne 0) { Write-Error "Login failed"; exit 1 }

# Step 2 — Create named tunnel (permanent tunnel ID)
Write-Host "`nStep 2: Creating named tunnel '$TUNNEL'..." -ForegroundColor Yellow
$createOut = & $CF tunnel create $TUNNEL 2>&1
$createOut | Write-Host
if ($LASTEXITCODE -ne 0 -and $createOut -notmatch "already exists") {
    Write-Error "Failed to create tunnel"; exit 1
}

# Extract tunnel ID
$tunnelId = (& $CF tunnel list --output json 2>$null | ConvertFrom-Json |
    Where-Object { $_.name -eq $TUNNEL }).id
Write-Host "Tunnel ID: $tunnelId"

# Step 3 — Create DNS CNAME record in Cloudflare
Write-Host "`nStep 3: Creating DNS record $HOSTNAME -> $tunnelId.cfargotunnel.com..." -ForegroundColor Yellow
& $CF tunnel route dns $TUNNEL $HOSTNAME
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create DNS route"; exit 1 }

# Step 4 — Write cloudflared config file
$cfDir    = "$env:USERPROFILE\.cloudflared"
$cfConfig = "$cfDir\config.yml"
New-Item -ItemType Directory -Force $cfDir | Out-Null

@"
tunnel: $tunnelId
credentials-file: $cfDir\$tunnelId.json

ingress:
  - hostname: $HOSTNAME
    service: http://localhost:$PORT
  - service: http_status:404
"@ | Out-File -Encoding utf8 $cfConfig

Write-Host "Config written to $cfConfig"

# Step 5 — Install cloudflared as a Windows service
Write-Host "`nStep 5: Installing cloudflared as Windows service..." -ForegroundColor Yellow
Write-Host "(This step requires running as Administrator)"
Start-Process -FilePath $CF `
    -ArgumentList "service install" `
    -Verb RunAs `
    -Wait

# Step 6 — Start the service
Start-Service cloudflared -ErrorAction SilentlyContinue

Write-Host "`n=== Setup complete! ===" -ForegroundColor Green
Write-Host "Permanent tunnel URL: https://$HOSTNAME" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Update GitHub secret:"
Write-Host "     gh secret set LUGH_SERVER_URL --body `"https://$HOSTNAME`" --repo IQS-LLC/phone-app"
Write-Host ""
Write-Host "  2. Trigger a new CI build to bake the permanent URL into apps:"
Write-Host "     git commit --allow-empty -m `"ci: bake permanent URL https://$HOSTNAME into apps`""
Write-Host "     git push"
Write-Host ""
Write-Host "  3. The tunnel now starts automatically with Windows as a service."
Write-Host "     Check status with:  Get-Service cloudflared"
