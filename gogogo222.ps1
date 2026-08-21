<#
.SYNOPSIS
    gogogo222.ps1 — Lugh Full-Stack Launch, Build & Deploy (native PowerShell)

.DESCRIPTION
    Automates the full Lugh development cycle on Windows without Git Bash:
    [1]  Verify required tools
    [2]  Start Docker Desktop + wait for daemon
    [3]  docker compose up — pull :latest Django image, bring stack up
    [4]  Wait for every container to be healthy
    [5]  Reload nginx (fixes upstream IP caching after container recreation)
    [6]  Start Cloudflare quick tunnel, capture public HTTPS URL
    [7]  Update GitHub secret LUGH_SERVER_URL with new URL
    [8]  Write build-manifest.json with timestamp + URL + git SHA
    [9]  git commit + push → triggers CI (Android APK + iOS IPA)
    [10] Monitor CI run on GitHub Actions
    [11] Download APK + IPA artifacts to Desktop
    [12] Helm deploy (optional — skips gracefully when disabled/offline)

.PARAMETER Mode
    Run only a specific step group:
      docker   steps 2-5  (start stack)
      tunnel   steps 6-7  (tunnel + GitHub secret)
      deploy   steps 8-11 (commit + CI + download)
      helm     step  12   (Helm only)
      status   show current state without changing anything

.PARAMETER NoWait
    Skip CI monitoring after git push (steps 10-11).

.PARAMETER HelmDeploy
    Enable the Helm deploy step. Requires kubectl + helm in PATH
    and a reachable cluster. Skips gracefully if either is missing.

.EXAMPLE
    .\gogogo222.ps1                     # full run
    .\gogogo222.ps1 -Mode docker        # start stack only
    .\gogogo222.ps1 -Mode status        # check state
    .\gogogo222.ps1 -NoWait             # full run, skip CI wait
    .\gogogo222.ps1 -Mode deploy        # commit + CI + download
    .\gogogo222.ps1 -HelmDeploy         # full run + Helm
    HELM_DEPLOY=true .\gogogo222.ps1    # same via env var

.NOTES
    Required tools: docker, git, gh
    Optional tools: cloudflared (tunnel), helm + kubectl (Helm deploy)

    GitHub Secrets that must exist:
      LUGH_SERVER_URL      — set automatically by this script
      DOCKERHUB_USERNAME   — your Docker Hub handle
      DOCKERHUB_TOKEN      — Docker Hub access token (read/write)
      DJANGO_SECRET_KEY    — production Django SECRET_KEY
      DB_PASSWORD          — PostgreSQL password
      ANDROID_KEYSTORE_B64 — base64 release keystore
      ANDROID_STORE_PASSWORD / ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD

    Logs written to:  C:\ProgramData\Lugh\logs\
    Artifacts saved to: C:\Users\Automation\Desktop\
#>

[CmdletBinding()]
param(
    [ValidateSet("", "docker", "tunnel", "deploy", "helm", "status")]
    [string]$Mode = "",
    [switch]$NoWait,
    [switch]$HelmDeploy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG — every tunable lives here; override via environment variable or edit
# ─────────────────────────────────────────────────────────────────────────────

$Cfg = @{
    # Project
    ProjectDir       = if ($env:PROJECT_DIR)       { $env:PROJECT_DIR }       else { "C:\Users\Automation\Desktop\phoneapp+apartment-16\phone-app" }
    ComposeFile      = if ($env:COMPOSE_FILE)       { $env:COMPOSE_FILE }      else { "docker-compose.dev.yml" }

    # Docker
    DockerDesktopExe = if ($env:DOCKER_DESKTOP_EXE){ $env:DOCKER_DESKTOP_EXE} else { "C:\Program Files\Docker\Docker\Docker Desktop.exe" }
    NginxContainer   = if ($env:NGINX_CONTAINER)   { $env:NGINX_CONTAINER }   else { "lugh_nginx" }
    DjangoContainer  = if ($env:DJANGO_CONTAINER)  { $env:DJANGO_CONTAINER }  else { "lugh_django" }

    # Tunnel
    CloudflaredExe   = if ($env:CLOUDFLARED_EXE)   { $env:CLOUDFLARED_EXE }   else { "C:\Users\Automation\Desktop\cloudflared.exe" }
    TunnelPort       = if ($env:TUNNEL_PORT)        { $env:TUNNEL_PORT }       else { "8090" }
    # How many concurrent quick tunnels to run — temporary multi-endpoint
    # failover bridge (2026-08-21) until the server has real WAN
    # connectivity, so a single dead/slow/edge-throttled Cloudflare tunnel
    # can't take the app down. All N point at the SAME local backend
    # (TunnelPort) and get independent trycloudflare.com hostnames; the
    # Flutter-side RuntimeConfig endpoint pool (lib/config/runtime_config.dart)
    # health-checks and fails over between whichever of these are up.
    TunnelCount      = if ($env:TUNNEL_COUNT)       { [int]$env:TUNNEL_COUNT } else { 3 }

    # GitHub
    GithubRepo       = if ($env:GITHUB_REPO)        { $env:GITHUB_REPO }       else { "IQS-LLC/phone-app" }
    GithubSecret     = if ($env:GITHUB_SECRET_NAME) { $env:GITHUB_SECRET_NAME} else { "LUGH_SERVER_URL" }
    GitBranch        = if ($env:GIT_BRANCH)         { $env:GIT_BRANCH }        else { "main" }
    ArtifactApk      = if ($env:ARTIFACT_APK_NAME)  { $env:ARTIFACT_APK_NAME } else { "lugh-android-apk" }
    ArtifactIpa      = if ($env:ARTIFACT_IPA_NAME)  { $env:ARTIFACT_IPA_NAME } else { "lugh-ios-ipa" }

    # Output paths
    LogDir           = if ($env:LOG_DIR)            { $env:LOG_DIR }           else { "C:\ProgramData\Lugh\logs" }
    ArtifactsDir     = if ($env:ARTIFACTS_DIR)      { $env:ARTIFACTS_DIR }     else { "C:\ProgramData\Lugh\artifacts" }
    DesktopDir       = if ($env:DESKTOP_DIR)        { $env:DESKTOP_DIR }       else { "C:\Users\Automation\Desktop" }

    # Helm
    HelmRelease      = if ($env:HELM_RELEASE)       { $env:HELM_RELEASE }      else { "lugh" }
    HelmNamespace    = if ($env:HELM_NAMESPACE)      { $env:HELM_NAMESPACE }    else { "lugh" }
    HelmChart        = if ($env:HELM_CHART)          { $env:HELM_CHART }        else { "infra\helm\lugh" }
    HelmValues       = if ($env:HELM_VALUES)         { $env:HELM_VALUES }       else { "" }
    HelmTimeout      = if ($env:HELM_WAIT_TIMEOUT)   { $env:HELM_WAIT_TIMEOUT } else { "300" }

    # Timeouts (seconds)
    WaitDocker       = if ($env:WAIT_DOCKER)         { [int]$env:WAIT_DOCKER }  else { 120 }
    WaitHealthy      = if ($env:WAIT_HEALTHY)        { [int]$env:WAIT_HEALTHY } else { 120 }
    WaitTunnel       = if ($env:WAIT_TUNNEL)         { [int]$env:WAIT_TUNNEL }  else { 60  }
    WaitCI           = if ($env:WAIT_CI)             { [int]$env:WAIT_CI }      else { 1800 }
    CIPoll           = if ($env:CI_POLL)             { [int]$env:CI_POLL }      else { 20  }
    WaitCIAppear     = if ($env:WAIT_CI_APPEAR)      { [int]$env:WAIT_CI_APPEAR}else { 90  }
}

# ─────────────────────────────────────────────────────────────────────────────
# GLOBALS — internal state
# ─────────────────────────────────────────────────────────────────────────────

$Script:Version    = "1.0.0"
$Script:StartTime  = Get-Date
$Script:RunTs      = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
# TunnelUrl stays a single string — the *first* successfully captured URL —
# for backward compatibility with the manifest/Helm/summary display below,
# which only ever showed one. TunnelUrls (plural) is the real list the
# multi-endpoint failover pool actually needs; it's what gets pushed to the
# GitHub secret.
$Script:TunnelUrl  = ""
$Script:TunnelUrls = @()
$Script:CIRunId    = ""
$Script:CIStatus   = ""
$Script:CfProcs    = @()
$Script:CfLogFiles = @()

[void](New-Item -ItemType Directory -Force -Path $Cfg.LogDir, $Cfg.ArtifactsDir)

$Script:LogFile   = Join-Path $Cfg.LogDir "gogogo222-$($Script:RunTs).log"

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────

function Write-L {
    param(
        [string]$Message,
        [ValidateSet("INFO","OK","WARN","ERROR","STEP","DATA")]
        [string]$Level = "INFO"
    )
    $ts    = Get-Date -Format "HH:mm:ss"
    $plain = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Level] $Message"
    Add-Content -Path $Script:LogFile -Value $plain -Encoding UTF8

    $color = switch ($Level) {
        "OK"    { "Green"    }
        "WARN"  { "Yellow"   }
        "ERROR" { "Red"      }
        "STEP"  { "Cyan"     }
        "DATA"  { "DarkGray" }
        default { "White"    }
    }
    $icon = switch ($Level) {
        "OK"    { "[OK]   " }
        "WARN"  { "[WARN] " }
        "ERROR" { "[ERR]  " }
        "STEP"  { "[STEP] " }
        "DATA"  { "       " }
        default { "[INFO] " }
    }
    Write-Host "[$ts]$icon$Message" -ForegroundColor $color
}

function Write-Step {
    param([string]$Title)
    $bar = "─" * 52
    Write-Host ""
    Write-Host $bar -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor Cyan
    Add-Content -Path $Script:LogFile -Value "`n[STEP] $Title" -Encoding UTF8
}

function Write-LOk    { param([string]$M) Write-L $M -Level OK    }
function Write-LWarn  { param([string]$M) Write-L $M -Level WARN  }
function Write-LError { param([string]$M) Write-L $M -Level ERROR }
function Write-LData  { param([string]$M) Write-L $M -Level DATA  }

function Get-Elapsed {
    $e = (Get-Date) - $Script:StartTime
    return "{0}m{1:D2}s" -f [int]$e.TotalMinutes, $e.Seconds
}

function Stop-WithError {
    param([string]$Message)
    Write-LError $Message
    Write-LError "Full log: $($Script:LogFile)"
    # Kill every cloudflared tunnel process we started
    foreach ($p in $Script:CfProcs) {
        if ($p -and -not $p.HasExited) {
            $p | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Dependency check
# ─────────────────────────────────────────────────────────────────────────────

function Step-CheckDeps {
    Write-Step "STEP 1 / DEPENDENCY CHECK"

    $missing = @()
    foreach ($cmd in @("docker", "git", "gh")) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) {
            Write-LOk "$cmd : $($found.Source)"
        } else {
            Write-LError "$cmd : NOT FOUND"
            $missing += $cmd
        }
    }

    # cloudflared — can live at config path or in PATH
    if (Test-Path $Cfg.CloudflaredExe) {
        Write-LOk "cloudflared : $($Cfg.CloudflaredExe)"
    } elseif ($cf = Get-Command cloudflared -ErrorAction SilentlyContinue) {
        $Cfg.CloudflaredExe = $cf.Source
        Write-LOk "cloudflared : $($Cfg.CloudflaredExe)"
    } else {
        Write-LWarn "cloudflared : not found — tunnel step will be skipped"
        Write-LData  "Download: https://github.com/cloudflare/cloudflared/releases/latest"
    }

    if ($missing.Count -gt 0) {
        Stop-WithError "Missing: $($missing -join ', '). Install them and re-run."
    }

    # Check gh auth
    $null = gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-LWarn "gh not authenticated — run: gh auth login"
        Write-LWarn "Secret update + CI monitoring will be skipped"
    } else {
        Write-LOk "gh : authenticated"
    }

    Write-LOk "Dependency check passed"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Docker Desktop
# ─────────────────────────────────────────────────────────────────────────────

function Step-DockerDesktop {
    Write-Step "STEP 2 / DOCKER DESKTOP"

    $null = docker info 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-LOk "Docker daemon already running"
        return
    }

    Write-L "Starting Docker Desktop..."
    if (-not (Test-Path $Cfg.DockerDesktopExe)) {
        Stop-WithError "Docker Desktop not found at: $($Cfg.DockerDesktopExe)"
    }

    Start-Process -FilePath $Cfg.DockerDesktopExe -WindowStyle Minimized

    $deadline = [datetime]::Now.AddSeconds($Cfg.WaitDocker)
    $attempt  = 0
    while ([datetime]::Now -lt $deadline) {
        $attempt++
        Start-Sleep -Seconds 5
        $null = docker info 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-LOk "Docker daemon ready (waited ~$($attempt * 5)s)"
            return
        }
        Write-LData "Waiting for daemon... ($($attempt * 5)s)"
    }

    Stop-WithError "Docker Desktop did not start within $($Cfg.WaitDocker)s"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — docker compose up
# ─────────────────────────────────────────────────────────────────────────────

function Step-ComposeUp {
    Write-Step "STEP 3 / DOCKER COMPOSE UP"

    Push-Location $Cfg.ProjectDir
    try {
        # Pull latest Django image from Docker Hub (public, no auth needed)
        Write-L "Pulling latest Django image from Docker Hub..."
        docker compose -f $Cfg.ComposeFile pull django 2>&1 |
            ForEach-Object { Write-LData $_ }

        Write-L "Starting stack (detached)..."
        docker compose -f $Cfg.ComposeFile up -d --remove-orphans 2>&1 |
            ForEach-Object { Write-LData $_ }

        if ($LASTEXITCODE -ne 0) {
            Stop-WithError "docker compose up failed — see log: $($Script:LogFile)"
        }

        Write-LOk "Stack started"

        # Capture container logs for troubleshooting
        $containerLog = Join-Path $Cfg.LogDir "containers-$($Script:RunTs).log"
        docker compose -f $Cfg.ComposeFile logs --no-color 2>&1 |
            Out-File -FilePath $containerLog -Encoding UTF8
        Write-LData "Container logs: $containerLog"

    } finally {
        Pop-Location
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Wait for all containers to be healthy
# ─────────────────────────────────────────────────────────────────────────────

function Step-WaitHealthy {
    Write-Step "STEP 4 / WAIT FOR HEALTHY CONTAINERS"

    $containers = @("lugh_db", "lugh_redis", "lugh_mock_plc", "lugh_django", "lugh_nginx")
    $deadline   = [datetime]::Now.AddSeconds($Cfg.WaitHealthy)
    $attempt    = 0

    while ([datetime]::Now -lt $deadline) {
        $attempt++
        $allGood = $true

        foreach ($c in $containers) {
            $status = docker inspect $c --format "{{.State.Health.Status}}" 2>&1
            if ($status -ne "healthy") {
                $allGood = $false
                Write-LData "$c : $status"
            }
        }

        if ($allGood) {
            Write-LOk "All containers healthy (attempt $attempt, $(Get-Elapsed) elapsed)"
            return
        }

        Write-LData "Not all healthy yet — attempt $attempt ($(Get-Elapsed))"
        Start-Sleep -Seconds 5
    }

    Write-LWarn "Timed out waiting for healthy containers — continuing (nginx reload may still fix things)"
    Push-Location $Cfg.ProjectDir
    docker compose -f $Cfg.ComposeFile ps 2>&1 | ForEach-Object { Write-LData $_ }
    Pop-Location
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Nginx reload
# ─────────────────────────────────────────────────────────────────────────────

function Step-NginxReload {
    Write-Step "STEP 5 / NGINX RELOAD"

    Write-L "Reloading nginx (flushes cached upstream IPs)..."
    docker exec $Cfg.NginxContainer nginx -s reload 2>&1 |
        ForEach-Object { Write-LData $_ }

    if ($LASTEXITCODE -eq 0) {
        Write-LOk "Nginx reloaded"
    } else {
        Write-LWarn "Nginx reload returned non-zero (may be starting up)"
    }

    Start-Sleep -Seconds 2
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$($Cfg.TunnelPort)/health/" `
                               -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        Write-LOk "Health check: HTTP $($r.StatusCode)"
    } catch {
        Write-LWarn "Health check no response yet — stack is warming up"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Cloudflare Quick Tunnel
# ─────────────────────────────────────────────────────────────────────────────

function Step-Tunnel {
    Write-Step "STEP 6 / CLOUDFLARE QUICK TUNNELS ($($Cfg.TunnelCount)x, failover pool)"

    if (-not (Test-Path $Cfg.CloudflaredExe)) {
        Write-LWarn "cloudflared not found — skipping (local only at http://localhost:$($Cfg.TunnelPort))"
        return
    }

    # Kill any existing cloudflared instances — every prior run's tunnels,
    # not just one, since this now launches a pool.
    Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    $Script:CfProcs    = @()
    $Script:CfLogFiles = @()

    # All N processes proxy the SAME local backend — each just gets its own
    # independent trycloudflare.com hostname from Cloudflare's edge. This is
    # what makes the pool a real failover set rather than N copies of one
    # endpoint: if any one tunnel process dies or its hostname gets
    # throttled, the others are unaffected.
    for ($i = 1; $i -le $Cfg.TunnelCount; $i++) {
        $logFile = Join-Path $Cfg.LogDir "cloudflared-$($Script:RunTs)-$i.log"
        if (Test-Path $logFile) { Remove-Item $logFile -Force }

        Write-L "Starting cloudflared tunnel $i/$($Cfg.TunnelCount) → http://localhost:$($Cfg.TunnelPort)"
        $proc = Start-Process `
            -FilePath       $Cfg.CloudflaredExe `
            -ArgumentList   "tunnel --url http://localhost:$($Cfg.TunnelPort)" `
            -RedirectStandardError $logFile `
            -NoNewWindow `
            -PassThru

        $Script:CfProcs    += $proc
        $Script:CfLogFiles += $logFile
        Write-LData "  PID: $($proc.Id) | log: $logFile"
    }
    ($Script:CfProcs | ForEach-Object { $_.Id }) -join "`n" |
        Out-File -FilePath (Join-Path $Cfg.LogDir "cloudflared.pid") -Encoding ASCII

    # Poll every log until each has produced a URL, or the timeout hits —
    # partial success is fine (a 2-of-3 pool still fails over fine), so this
    # doesn't retry or fail the whole step over one slow/dead process.
    $deadline = [datetime]::Now.AddSeconds($Cfg.WaitTunnel)
    $Script:TunnelUrls = @()
    $pending = 0..($Script:CfLogFiles.Count - 1)

    while ([datetime]::Now -lt $deadline -and $pending.Count -gt 0) {
        Start-Sleep -Seconds 2
        $stillPending = @()
        foreach ($idx in $pending) {
            $logFile = $Script:CfLogFiles[$idx]
            $content = if (Test-Path $logFile) { Get-Content $logFile -Raw -ErrorAction SilentlyContinue } else { $null }
            if ($content -match 'https://[a-z0-9-]+\.trycloudflare\.com') {
                $Script:TunnelUrls += $Matches[0]
                Write-LOk "Tunnel $($idx + 1) URL: $($Matches[0])"
            } else {
                $stillPending += $idx
            }
        }
        $pending = $stillPending
    }

    if ($pending.Count -gt 0) {
        Write-LWarn "$($pending.Count)/$($Cfg.TunnelCount) tunnel(s) did not report a URL within $($Cfg.WaitTunnel)s — continuing with the $($Script:TunnelUrls.Count) that did"
    }

    if ($Script:TunnelUrls.Count -gt 0) {
        $Script:TunnelUrl = $Script:TunnelUrls[0]   # backward-compat single-URL display below
        Write-LOk "Pool ready: $($Script:TunnelUrls.Count) endpoint(s)"
        # Write without BOM so other tools can read it cleanly — one URL per
        # line, first line is the primary for anything only reading line 1.
        [System.IO.File]::WriteAllText(
            (Join-Path $Cfg.LogDir "current-tunnel-url.txt"),
            ($Script:TunnelUrls -join "`n"),
            [System.Text.UTF8Encoding]::new($false)   # UTF-8 no BOM
        )
    } else {
        Write-LWarn "No tunnel captured a URL — check logs under $($Cfg.LogDir)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — Update GitHub secret
# ─────────────────────────────────────────────────────────────────────────────

function Step-UpdateSecret {
    Write-Step "STEP 7 / UPDATE GITHUB SECRET"

    if ($Script:TunnelUrls.Count -eq 0) {
        Write-LWarn "No tunnel URLs — skipping secret update"
        return
    }

    # Comma-separated list — RuntimeConfig (lib/config/runtime_config.dart)
    # splits this on commas into its endpoint pool. A single URL with no
    # comma still works exactly as before this change (fully backward
    # compatible), so this is safe even if TunnelCount is set to 1.
    $csv = $Script:TunnelUrls -join ","
    Write-L "Setting $($Cfg.GithubSecret) → $($Script:TunnelUrls.Count) endpoint(s)"
    Write-LData $csv
    $csv | gh secret set $Cfg.GithubSecret --repo $Cfg.GithubRepo 2>&1 |
        ForEach-Object { Write-LData $_ }

    if ($LASTEXITCODE -eq 0) {
        Write-LOk "GitHub secret updated"
    } else {
        Write-LWarn "Secret update failed — run: gh auth login"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — Build manifest + git commit + push
# ─────────────────────────────────────────────────────────────────────────────

function Step-CommitPush {
    Write-Step "STEP 8 / BUILD MANIFEST + GIT COMMIT + PUSH"

    Push-Location $Cfg.ProjectDir
    try {
        $gitSha = git rev-parse HEAD 2>&1 | Select-Object -First 1

        # Build manifest
        $manifest = [ordered]@{
            build_date      = Get-Date -Format "yyyy-MM-dd"
            build_timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
            server_url      = $Script:TunnelUrl       # primary — backward compat
            server_urls     = $Script:TunnelUrls       # full failover pool
            git_sha_before  = "$gitSha"
            trigger         = "gogogo222.ps1"
            run_ts          = $Script:RunTs
            script_version  = $Script:Version
        }
        $manifest | ConvertTo-Json -Depth 3 |
            Out-File -FilePath (Join-Path $Cfg.ProjectDir "build-manifest.json") -Encoding UTF8
        Write-LOk "build-manifest.json written"

        git add "build-manifest.json" 2>&1 | ForEach-Object { Write-LData $_ }

        $dirty = git status --porcelain 2>&1
        if ($dirty) {
            $shortUrl = if ($Script:TunnelUrl) {
                ($Script:TunnelUrl -replace 'https://', '').Split('.')[0]
            } else { "local" }
            $msg = "chore: build $(Get-Date -Format 'yyyy-MM-dd HH:mm') [$shortUrl]"
            git commit -m $msg 2>&1 | ForEach-Object { Write-LData $_ }
            Write-LOk "Committed: $msg"
        } else {
            Write-LData "Nothing new to commit"
        }

        Write-L "Pushing to origin/$($Cfg.GitBranch)..."
        git push origin $Cfg.GitBranch 2>&1 | ForEach-Object { Write-LData $_ }
        if ($LASTEXITCODE -eq 0) {
            Write-LOk "Pushed — CI triggered"
            Write-LData "Watch: https://github.com/$($Cfg.GithubRepo)/actions"
        } else {
            Write-LWarn "Push returned non-zero"
        }

    } finally {
        Pop-Location
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 — Monitor CI run
# ─────────────────────────────────────────────────────────────────────────────

function Step-WaitCI {
    Write-Step "STEP 9 / MONITOR CI RUN"

    # Wait for the new run to show up
    Write-L "Waiting for CI run to appear..."
    $appearBy = [datetime]::Now.AddSeconds($Cfg.WaitCIAppear)

    while ([datetime]::Now -lt $appearBy) {
        Start-Sleep -Seconds 5
        $raw = gh run list --repo $Cfg.GithubRepo --branch $Cfg.GitBranch `
                           --limit 1 --json databaseId,status,conclusion 2>&1
        if ($LASTEXITCODE -eq 0) {
            try {
                $runs = $raw | ConvertFrom-Json
                if ($runs.Count -gt 0) {
                    $Script:CIRunId = "$($runs[0].databaseId)"
                    Write-LOk "CI run #$($Script:CIRunId) found"
                    Write-LData "https://github.com/$($Cfg.GithubRepo)/actions/runs/$($Script:CIRunId)"
                    break
                }
            } catch { }
        }
        Write-LData "No run yet..."
    }

    if ([string]::IsNullOrEmpty($Script:CIRunId)) {
        Write-LWarn "CI run did not appear — check GitHub Actions manually"
        return $false
    }

    # Poll until complete
    $ciBy = [datetime]::Now.AddSeconds($Cfg.WaitCI)
    while ([datetime]::Now -lt $ciBy) {
        Start-Sleep -Seconds $Cfg.CIPoll

        $raw = gh run view $Script:CIRunId --repo $Cfg.GithubRepo `
                           --json status,conclusion 2>&1
        if ($LASTEXITCODE -ne 0) { Write-LData "gh error — retrying..."; continue }

        try {
            $info       = $raw | ConvertFrom-Json
            $status     = $info.status
            $conclusion = $info.conclusion

            Write-LData "status=$status conclusion=$conclusion elapsed=$(Get-Elapsed)"

            if ($status -eq "completed") {
                $Script:CIStatus = $conclusion
                if ($conclusion -eq "success") {
                    Write-LOk "CI PASSED ($(Get-Elapsed))"
                    return $true
                } else {
                    Write-LWarn "CI finished: $conclusion"
                    Write-LData "Logs: https://github.com/$($Cfg.GithubRepo)/actions/runs/$($Script:CIRunId)"
                    return $false
                }
            }
        } catch {
            Write-LData "Parse error — retrying"
        }
    }

    Write-LWarn "CI timed out after $($Cfg.WaitCI)s"
    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10 — Download artifacts
# ─────────────────────────────────────────────────────────────────────────────

function Step-DownloadArtifacts {
    Write-Step "STEP 10 / DOWNLOAD ARTIFACTS"

    if ([string]::IsNullOrEmpty($Script:CIRunId)) {
        Write-LWarn "No CI run ID — skipping"
        return
    }

    $outDir = Join-Path $Cfg.ArtifactsDir $Script:RunTs
    [void](New-Item -ItemType Directory -Force -Path $outDir)
    Write-LData "Destination: $outDir"

    # Android APK
    Write-L "Downloading APK ($($Cfg.ArtifactApk))..."
    gh run download $Script:CIRunId `
        --repo $Cfg.GithubRepo `
        --name $Cfg.ArtifactApk `
        --dir  $outDir 2>&1 | ForEach-Object { Write-LData $_ }

    if ($LASTEXITCODE -eq 0) {
        $apk = Get-ChildItem -Path $outDir -Filter "*.apk" -Recurse | Select-Object -First 1
        if ($apk) {
            $dest = Join-Path $Cfg.DesktopDir "lugh-android-latest.apk"
            Copy-Item $apk.FullName $dest -Force
            $sz = [math]::Round($apk.Length / 1MB, 1)
            Write-LOk "APK: $dest ($sz MB)"
        }
    } else {
        Write-LWarn "APK download failed"
    }

    # iOS IPA
    Write-L "Downloading IPA ($($Cfg.ArtifactIpa))..."
    gh run download $Script:CIRunId `
        --repo $Cfg.GithubRepo `
        --name $Cfg.ArtifactIpa `
        --dir  $outDir 2>&1 | ForEach-Object { Write-LData $_ }

    if ($LASTEXITCODE -eq 0) {
        $ipa = Get-ChildItem -Path $outDir -Filter "*.ipa" -Recurse | Select-Object -First 1
        if ($ipa) {
            $dest = Join-Path $Cfg.DesktopDir "lugh-ios-latest.ipa"
            Copy-Item $ipa.FullName $dest -Force
            $sz = [math]::Round($ipa.Length / 1MB, 1)
            Write-LOk "IPA: $dest ($sz MB)"
        }
    } else {
        Write-LWarn "IPA download failed"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 11 — Helm deploy (optional)
# ─────────────────────────────────────────────────────────────────────────────

function Step-HelmDeployFn {
    Write-Step "STEP 11 / HELM DEPLOY (KUBERNETES)"

    $enabled = $HelmDeploy -or ($env:HELM_DEPLOY -eq "true")
    if (-not $enabled) {
        Write-L "Helm deploy disabled — pass -HelmDeploy or set HELM_DEPLOY=true to enable"
        Write-LData "Use when k3s cluster is back online (NAS or cloud)"
        return
    }

    foreach ($bin in @("helm", "kubectl")) {
        if (-not (Get-Command $bin -ErrorAction SilentlyContinue)) {
            Write-LWarn "$bin not found — skipping Helm deploy"
            Write-LData "Install helm: https://helm.sh/docs/intro/install/"
            return
        }
    }

    $null = kubectl cluster-info 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-LWarn "kubectl cannot reach cluster — k3s offline or KUBECONFIG not set"
        Write-LData "Set KUBECONFIG and re-run with -HelmDeploy once cluster is back"
        return
    }

    $chartPath = Join-Path $Cfg.ProjectDir $Cfg.HelmChart
    if (-not (Test-Path (Join-Path $chartPath "Chart.yaml"))) {
        Write-LWarn "Chart not found at $chartPath — skipping"
        return
    }

    Push-Location $Cfg.ProjectDir
    $gitSha = "sha-$(git rev-parse HEAD 2>&1 | Select-Object -First 1)"
    Pop-Location

    $helmArgs = @(
        "upgrade", "--install", $Cfg.HelmRelease, $chartPath,
        "--namespace",       $Cfg.HelmNamespace,
        "--create-namespace",
        "--wait",
        "--timeout",         "$($Cfg.HelmTimeout)s",
        "--atomic",
        "--cleanup-on-fail",
        "--set",             "image.tag=$gitSha"
    )

    if ($Script:TunnelUrls.Count -gt 0) {
        $csv = $Script:TunnelUrls -join ","
        $helmArgs += @("--set", "env.LUGH_SERVER_URL=$csv")
    }

    if ($Cfg.HelmValues -and (Test-Path $Cfg.HelmValues)) {
        $helmArgs += @("-f", $Cfg.HelmValues)
        Write-LData "Extra values: $($Cfg.HelmValues)"
    }

    Write-L "helm $($helmArgs -join ' ')"
    helm @helmArgs 2>&1 | ForEach-Object { Write-LData $_ }

    if ($LASTEXITCODE -eq 0) {
        Write-LOk "Helm deploy succeeded — release=$($Cfg.HelmRelease) ns=$($Cfg.HelmNamespace)"
        kubectl get pods -n $Cfg.HelmNamespace 2>&1 | ForEach-Object { Write-LData $_ }
    } else {
        Write-LWarn "Helm deploy FAILED — Docker Compose stack still running, non-fatal"
        helm history $Cfg.HelmRelease -n $Cfg.HelmNamespace 2>&1 |
            ForEach-Object { Write-LData $_ }
        kubectl get events -n $Cfg.HelmNamespace --sort-by=".lastTimestamp" 2>&1 |
            Select-Object -Last 20 | ForEach-Object { Write-LData $_ }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS — read-only snapshot of current state
# ─────────────────────────────────────────────────────────────────────────────

function Step-Status {
    Write-Step "STATUS"

    Push-Location $Cfg.ProjectDir
    Write-L "Docker containers:"
    docker compose -f $Cfg.ComposeFile ps 2>&1 | ForEach-Object { Write-LData $_ }
    Pop-Location

    $urlFile = Join-Path $Cfg.LogDir "current-tunnel-url.txt"
    $url = if (Test-Path $urlFile) { (Get-Content $urlFile -Raw).Trim() } else { "none" }
    Write-LData "Tunnel URL: $url"

    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$($Cfg.TunnelPort)/health/" `
                               -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        Write-LOk "Local health: HTTP $($r.StatusCode)"
    } catch {
        Write-LWarn "Local health check failed"
    }

    Write-L "Last CI run:"
    gh run list --repo $Cfg.GithubRepo --branch $Cfg.GitBranch --limit 1 2>&1 |
        ForEach-Object { Write-LData $_ }

    foreach ($name in @("lugh-android-latest.apk", "lugh-ios-latest.ipa")) {
        $fp = Join-Path $Cfg.DesktopDir $name
        if (Test-Path $fp) {
            $sz = [math]::Round((Get-Item $fp).Length / 1MB, 1)
            Write-LOk "$name : exists ($sz MB)"
        } else {
            Write-LWarn "$name : not on Desktop"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

function Write-Summary {
    $el = Get-Elapsed
    Write-Host ""
    Write-Host ("═" * 54) -ForegroundColor Cyan
    Write-Host "  LUGH STACK READY  —  $el" -ForegroundColor Cyan
    Write-Host ("═" * 54) -ForegroundColor Cyan
    Write-Host ""

    if ($Script:TunnelUrls.Count -gt 0) {
        Write-LOk "Server URLs : $($Script:TunnelUrls.Count) endpoint(s) (failover pool)"
        foreach ($u in $Script:TunnelUrls) { Write-LData "  - $u" }
    } else {
        Write-LOk "Server URL  : not set — check tunnel log"
    }
    Write-LOk "Local URL   : http://localhost:$($Cfg.TunnelPort)"
    Write-LOk "Android APK : $(Join-Path $Cfg.DesktopDir 'lugh-android-latest.apk')"
    Write-LOk "iOS IPA     : $(Join-Path $Cfg.DesktopDir 'lugh-ios-latest.ipa')"

    if ($Script:CIRunId) {
        Write-LOk "CI Run      : https://github.com/$($Cfg.GithubRepo)/actions/runs/$($Script:CIRunId)"
        Write-LOk "CI Status   : $($Script:CIStatus)"
    }

    Write-LOk "Log file    : $($Script:LogFile)"
    Write-Host ""
    Write-L "Android: transfer APK to phone → Settings > Security > Unknown sources → install"
    Write-L "iOS    : drag IPA into Sideloadly with iPhone plugged in; trust cert in Settings"
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

function Main {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  gogogo222.ps1  v$($Script:Version)  (PowerShell native)         ║" -ForegroundColor Cyan
    Write-Host "║  Lugh Full-Stack Launch, Build & Deploy              ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "  Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkCyan
    Write-Host "  Log     : $($Script:LogFile)" -ForegroundColor DarkCyan
    Write-Host "  Mode    : $(if ($Mode) { $Mode } else { 'full' })$(if ($NoWait) { ' --no-wait' })" -ForegroundColor DarkCyan
    Write-Host ""

    Write-L "=== gogogo222.ps1 v$($Script:Version) start run_ts=$($Script:RunTs) ==="

    switch ($Mode) {

        "docker" {
            Step-CheckDeps; Step-DockerDesktop; Step-ComposeUp; Step-WaitHealthy; Step-NginxReload
            Write-Summary
        }

        "tunnel" {
            Step-CheckDeps; Step-Tunnel; Step-UpdateSecret
            Write-Summary
        }

        "deploy" {
            Step-CheckDeps; Step-CommitPush
            $ok = Step-WaitCI
            if ($ok) { Step-DownloadArtifacts } else { Write-LWarn "CI incomplete — download manually later" }
            Step-HelmDeployFn
            Write-Summary
        }

        "helm" {
            Step-CheckDeps; Step-HelmDeployFn
        }

        "status" {
            Step-Status
        }

        default {
            Step-CheckDeps
            Step-DockerDesktop
            Step-ComposeUp
            Step-WaitHealthy
            Step-NginxReload
            Step-Tunnel
            Step-UpdateSecret
            Step-CommitPush
            if (-not $NoWait) {
                $ok = Step-WaitCI
                if ($ok) {
                    Step-DownloadArtifacts
                } else {
                    Write-LWarn "CI incomplete — run: .\gogogo222.ps1 -Mode deploy  when CI finishes"
                }
            } else {
                Write-LWarn "-NoWait: skipping CI monitoring"
                Write-L "Track at: https://github.com/$($Cfg.GithubRepo)/actions"
            }
            Step-HelmDeployFn
            Write-Summary
        }
    }

    Write-L "=== gogogo222.ps1 done ==="
}

Main
