# Install the FeiYin sync server as an auto-start task on this Windows machine.
# Run:  powershell -ExecutionPolicy Bypass -File install-autostart.ps1
# Optional: -Port 8787 -NoFirewall
param(
    [string]$TaskName = "FeiYinSync",
    [int]$Port = 8787,
    [switch]$NoFirewall
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcher = Join-Path $here "launch-hidden.vbs"

if (-not (Test-Path $launcher)) { throw "launch-hidden.vbs not found next to this script" }
if (-not (Test-Path (Join-Path $here "index.js"))) { throw "index.js not found next to this script" }

# ---- 1. scheduled task (starts at logon, no admin required) ----
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument ('"' + $launcher + '"') -WorkingDirectory $here
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger $trigger -Settings $settings `
    -Description "FeiYin account and data sync service (node, port $Port)" -Force | Out-Null
Write-Host "[ok] scheduled task registered: $TaskName"

Start-ScheduledTask -TaskName $TaskName
Write-Host "[ok] task started"

# ---- 2. firewall rule (needs admin, skipped otherwise) ----
if (-not $NoFirewall) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $ruleName = "FeiYin Sync $Port"
    if ($isAdmin) {
        $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP `
                -LocalPort $Port -Action Allow -Profile Private | Out-Null
            Write-Host "[ok] firewall rule added for TCP $Port (private network)"
        } else {
            Write-Host "[ok] firewall rule already present"
        }
    } else {
        Write-Host "[warn] not running as administrator, firewall rule NOT added."
        Write-Host "       Run this once in an admin PowerShell if your phone cannot connect:"
        Write-Host "       netsh advfirewall firewall add rule name=`"FeiYin Sync $Port`" dir=in action=allow protocol=TCP localport=$Port"
    }
}

# ---- 3. wait for the port and report ----
$ok = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $r = Invoke-WebRequest -Uri ("http://127.0.0.1:" + $Port + "/v1/health") -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) { $ok = $true; Write-Host ("[ok] health: " + $r.Content); break }
    } catch { }
}
if (-not $ok) {
    Write-Host "[fail] service did not answer on port $Port within 10s."
    Write-Host "       Check logs\server.log"
    exit 1
}

# ---- 4. print LAN addresses ----
Write-Host ""
Write-Host "Service is up. Use one of these in the app:"
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    ForEach-Object { Write-Host ("   http://" + $_.IPAddress + ":" + $Port + "   (" + $_.InterfaceAlias + ")") }
