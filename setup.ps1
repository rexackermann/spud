#Requires -RunAsAdministrator
# Spud — Windows reverse tunnel installer
# Uses bore.pub as relay, ntfy.sh for push notifications.
# No VPS needed. Supports Windows 7 SP1+.
#
# Run as Administrator:
#   iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/rex/spud/main/setup.ps1'))

$ErrorActionPreference = "Stop"

# ── Configure these before publishing ────────────────────────────────────
$AdminPubKey       = "ssh-ed25519 AAAA_REPLACE_WITH_YOUR_PUBLIC_KEY spud-admin"
$NtfyTopicPrefix   = "spud-REPLACE_WITH_RANDOM_STRING"
# ─────────────────────────────────────────────────────────────────────────

$SpudDir     = "$env:ProgramData\spud"
$BorePath    = "$SpudDir\bore.exe"
$LoopScript  = "$SpudDir\tunnel-loop.ps1"

function Log { param($m) Write-Host "[spud] $m" }
function Die { param($m) Write-Error "[spud] ERROR: $m"; exit 1 }

Log "Spud installer — $([System.Environment]::OSVersion.VersionString) ($env:PROCESSOR_ARCHITECTURE)"

# Check placeholders
if ($AdminPubKey -like "*REPLACE*")     { Die "Set AdminPubKey in setup.ps1 before running." }
if ($NtfyTopicPrefix -like "*REPLACE*") { Die "Set NtfyTopicPrefix in setup.ps1 before running." }

New-Item -ItemType Directory -Force -Path $SpudDir | Out-Null

# ── OpenSSH Client ────────────────────────────────────────────────────────
$SshExe = (Get-Command ssh.exe -ErrorAction SilentlyContinue)?.Source

if (-not $SshExe) {
    Log "OpenSSH client not found. Trying to enable..."
    try {
        Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 | Out-Null
        $SshExe = (Get-Command ssh.exe -ErrorAction SilentlyContinue)?.Source
    } catch {}
}

if (-not $SshExe) {
    # Git for Windows ships ssh.exe — common on dev machines
    $gitCandidates = @(
        "C:\Program Files\Git\usr\bin\ssh.exe",
        "C:\Program Files (x86)\Git\usr\bin\ssh.exe",
        "C:\Windows\System32\OpenSSH\ssh.exe"
    )
    foreach ($c in $gitCandidates) {
        if (Test-Path $c) { $SshExe = $c; break }
    }
}

if (-not $SshExe) {
    Die "No SSH client found.`n  Win10/11: Settings > Apps > Optional Features > OpenSSH Client`n  Win7/8:   Install Git for Windows"
}
Log "SSH client: $SshExe"

# ── OpenSSH Server ────────────────────────────────────────────────────────
$SshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue

if (-not $SshdSvc) {
    Log "OpenSSH server not present. Enabling..."
    try {
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
        $SshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    } catch {
        Log "Warning: Could not enable OpenSSH Server automatically."
        Log "  Enable manually: Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
    }
}

if ($SshdSvc) {
    Set-Service -Name sshd -StartupType Automatic
    if ($SshdSvc.Status -ne 'Running') { Start-Service sshd }
    Log "SSH server running."

    # Disable password auth
    $SshDataDir  = "$env:ProgramData\ssh"
    $SshdConf    = "$SshDataDir\sshd_config"
    if (Test-Path $SshdConf) {
        $conf = Get-Content $SshdConf -Raw
        $conf = $conf -replace '(?m)^#?PasswordAuthentication\s+.*', 'PasswordAuthentication no'
        if ($conf -notmatch 'PasswordAuthentication') { $conf += "`nPasswordAuthentication no" }
        Set-Content $SshdConf $conf
        Restart-Service sshd -ErrorAction SilentlyContinue
    }
} else {
    Log "Warning: No SSH server available. Tunnel will open but you won't get a shell."
}

# ── Admin pubkey ──────────────────────────────────────────────────────────
$SshDataDir   = "$env:ProgramData\ssh"
$AuthKeysPath = "$SshDataDir\administrators_authorized_keys"
New-Item -ItemType Directory -Force -Path $SshDataDir | Out-Null

$existing = if (Test-Path $AuthKeysPath) { Get-Content $AuthKeysPath -Raw } else { "" }
if (-not $existing.Contains($AdminPubKey)) {
    Add-Content -Path $AuthKeysPath -Value $AdminPubKey
    Log "Admin pubkey installed."
}

# Fix ACLs — Windows OpenSSH ignores authorized_keys without correct permissions
try {
    icacls $AuthKeysPath /inheritance:r 2>&1 | Out-Null
    icacls $AuthKeysPath /grant "SYSTEM:(F)" 2>&1 | Out-Null
    icacls $AuthKeysPath /grant "BUILTIN\Administrators:(F)" 2>&1 | Out-Null
} catch { Log "Warning: Could not set ACL: $_" }

# ── Download bore ─────────────────────────────────────────────────────────
if (-not (Test-Path $BorePath)) {
    Log "Downloading bore..."
    try {
        $apiResp = (New-Object Net.WebClient).DownloadString("https://api.github.com/repos/ekzhang/bore/releases/latest")
        $ver = [regex]::Match($apiResp, '"tag_name"\s*:\s*"(v[^"]+)"').Groups[1].Value
    } catch { $ver = "v0.5.0" }

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
    $zipName = "bore-$ver-$arch.zip"
    $url  = "https://github.com/ekzhang/bore/releases/download/$ver/$zipName"
    $tmp  = "$SpudDir\bore.zip"

    try {
        (New-Object Net.WebClient).DownloadFile($url, $tmp)
    } catch {
        Die "Failed to download bore from $url`n  Error: $_"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($tmp)
    $entry = $zip.Entries | Where-Object { $_.Name -eq "bore.exe" } | Select-Object -First 1
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $BorePath, $true)
    $zip.Dispose()
    Remove-Item $tmp -Force
    Log "bore installed at $BorePath"
}

# ── Write tunnel loop script ──────────────────────────────────────────────
$NtfyTopic = "$NtfyTopicPrefix-$env:COMPUTERNAME"

@"
# Spud tunnel loop for Windows
`$BoreExe    = '$BorePath'
`$NtfyTopic  = '$NtfyTopic'

function Send-Notify {
    param(`$Port)
    `$msg = "ssh -p `$Port `$env:USERNAME@bore.pub  [`$env:COMPUTERNAME | `$(Get-Date -Format 'HH:mm')]"
    try {
        `$wc = New-Object Net.WebClient
        `$wc.Headers.Add("Title", "Spud: `$env:COMPUTERNAME online")
        `$wc.Headers.Add("Priority", "low")
        `$wc.Headers.Add("Tags", "computer")
        `$wc.UploadString("https://ntfy.sh/`$NtfyTopic", `$msg) | Out-Null
    } catch {}
}

while (`$true) {
    try {
        `$psi = New-Object Diagnostics.ProcessStartInfo
        `$psi.FileName  = `$BoreExe
        `$psi.Arguments = "local 22 --to bore.pub"
        `$psi.RedirectStandardOutput = `$true
        `$psi.RedirectStandardError  = `$true
        `$psi.UseShellExecute = `$false
        `$psi.CreateNoWindow  = `$true

        `$proc = [Diagnostics.Process]::Start(`$psi)

        # Read both stdout and stderr asynchronously
        `$action = {
            `$line = `$EventArgs.Data
            if (`$line -match 'listening at bore\.pub:(\d+)') {
                `$Port = `$Matches[1]
                Set-Content "`$env:ProgramData\spud\current_port" `$Port
                Send-Notify `$Port
            }
        }

        Register-ObjectEvent `$proc -EventName OutputDataReceived -Action `$action | Out-Null
        Register-ObjectEvent `$proc -EventName ErrorDataReceived  -Action `$action | Out-Null
        `$proc.BeginOutputReadLine()
        `$proc.BeginErrorReadLine()
        `$proc.WaitForExit()
    } catch {}
    Start-Sleep -Seconds 10
}
"@ | Set-Content $LoopScript

Log "Tunnel loop written to $LoopScript"

# ── Persistence (Scheduled Task) ─────────────────────────────────────────
$PsExe    = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$PsArgs   = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$LoopScript`""
$TaskName = "SpudTunnel"

$installed = $false

# Modern path: New-ScheduledTask cmdlets (Win8+ / PS3+)
if (Get-Command New-ScheduledTaskAction -ErrorAction SilentlyContinue) {
    try {
        Log "Installing scheduled task..."
        $action    = New-ScheduledTaskAction -Execute $PsExe -Argument $PsArgs
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet `
                         -AllowStartIfOnBatteries `
                         -DontStopIfGoingOnBatteries `
                         -StartWhenAvailable `
                         -RestartCount 999 `
                         -RestartInterval (New-TimeSpan -Minutes 1)
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $TaskName -Action $action `
            -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
        Start-ScheduledTask -TaskName $TaskName
        $installed = $true
        Log "Scheduled task installed."
    } catch { Log "New-ScheduledTask failed: $_" }
}

# Legacy path: schtasks.exe (Win XP SP2+)
if (-not $installed) {
    Log "Falling back to schtasks.exe..."
    $args = "/Create /F /RU SYSTEM /SC ONSTART /TN `"$TaskName`" /TR `"$PsExe $PsArgs`""
    Start-Process schtasks.exe -ArgumentList $args -Wait -NoNewWindow
    Start-Process schtasks.exe -ArgumentList "/Run /TN `"$TaskName`"" -Wait -NoNewWindow
    Log "schtasks entry created."
}

Log ""
Log "══════════════════════════════════════════════════════"
Log "  Spud installed."
Log ""
Log "  Watch for your connect command at:"
Log "    https://ntfy.sh/$NtfyTopic"
Log "  or install the ntfy app and subscribe to:"
Log "    $NtfyTopic"
Log ""
Log "  Current port (once tunnel is up):"
Log "    Get-Content $SpudDir\current_port"
Log "══════════════════════════════════════════════════════"
