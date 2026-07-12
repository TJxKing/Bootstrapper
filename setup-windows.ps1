<#
.SYNOPSIS
    Idempotent bootstrap for Windows Terminal / PowerShell 7.
.DESCRIPTION
    Presents an upfront selection menu and collects all input first, then runs
    unattended. Installs PowerShell 7 and Git if missing, then configures
    JetBrains Mono Nerd Font, Starship prompt, PSReadLine, a managed
    PowerShell profile block, global Git config, an ed25519 SSH key, and
    optional winget apps (VS Code, Claude, Obsidian, AutoHotkey, 7-Zip,
    Flameshot). Safe to re-run.
.NOTES
    Author:  TJ King
    Created: 2026-03
    Updated: 2026-07 — selection menu, optional winget apps, security hardening
#>

# =============================================================================
# Windows Terminal Bootstrap
# Idempotent setup: PS7, Git, Nerd Font, Starship, PSReadLine, PowerShell profile, SSH
# Run from Windows PowerShell 5 or PS7. `-ExecutionPolicy Bypass` on the command
# line applies to this process only — the machine-wide policy is unchanged:
#   powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1
# =============================================================================

#Region Bootstrap
# PS5-compatible block — must run before Set-StrictMode
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "[→]  PowerShell 7 not detected. Installing via winget..." -ForegroundColor Cyan
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "[✗]  winget not found. Install App Installer from the Microsoft Store, then re-run." -ForegroundColor Red
        exit 1
    }
    winget install --id Microsoft.PowerShell --silent --source winget --accept-package-agreements --accept-source-agreements
    $pwsh = Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe"
    if (Test-Path $pwsh) {
        Write-Host "[→]  Relaunching in PowerShell 7..." -ForegroundColor Cyan
        & $pwsh -ExecutionPolicy Bypass -File $PSCommandPath
    } else {
        Write-Host "[!]  PS7 installed. Open a new PowerShell 7 window and re-run the Quick Start block from the repo README." -ForegroundColor Yellow
    }
    exit
}
#EndRegion

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#Region Helpers
function Write-Info    ($msg) { Write-Host "[→]  $msg" -ForegroundColor Cyan }
function Write-Ok      ($msg) { Write-Host "[✓]  $msg" -ForegroundColor Green }
function Write-Warn    ($msg) { Write-Host "[!]  $msg" -ForegroundColor Yellow }
function Write-Err     ($msg) { Write-Host "[✗]  $msg" -ForegroundColor Red }
function Write-Section ($msg) {
    $pad = '─' * [Math]::Max(2, 44 - $msg.Length)
    Write-Host "`n── $msg $pad" -ForegroundColor Blue
}
function Write-Header ($title) {
    $inner = ("  $title").PadRight(46)
    Write-Host "`n╔$('═' * 46)╗" -ForegroundColor Blue
    Write-Host "║$inner║" -ForegroundColor Blue
    Write-Host "╚$('═' * 46)╝" -ForegroundColor Blue
}

# Only clear when attached to a console, so redirected output stays clean
function Clear-Screen {
    if (-not [Console]::IsOutputRedirected) { Clear-Host }
}
function Show-Banner {
    Clear-Screen
    Write-Header "Windows Terminal Bootstrap"
}

function Update-SessionPath {
    # Refresh PATH in the current session so freshly installed tools are callable
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}
#EndRegion

#Region Validation
function Test-PersonName {
    param([string]$Value)
    return $Value -match "^[\p{L}\p{N}][\p{L}\p{N} .'\-]{0,63}$"
}

function Test-EmailAddress {
    param([string]$Value)
    return $Value -match '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
}

function Read-ValidatedInput {
    param(
        [string]$Prompt,
        [scriptblock]$Validator,
        [string]$Hint,
        [switch]$AllowBlank
    )
    while ($true) {
        $value = Read-Host $Prompt
        if (-not $value) {
            if ($AllowBlank) { return '' }
            Write-Warn "A value is required. $Hint"
            continue
        }
        if (& $Validator $value) { return $value }
        Write-Warn "Invalid value. $Hint"
    }
}
#EndRegion

#Region Winget
function Test-WingetPrerequisite {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Err "winget not found. Install App Installer from the Microsoft Store and try again."
        exit 1
    }
    Write-Ok "winget found"

    # Refuse to install anything if the 'winget' source has been repointed away
    # from the official Microsoft CDN.
    $sourceInfo = winget source list --name winget 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $sourceInfo -notmatch [regex]::Escape('https://cdn.winget.microsoft.com/cache')) {
        Write-Err "The 'winget' source is missing or does not resolve to the official Microsoft CDN."
        Write-Err "Inspect it with 'winget source list', then restore defaults with 'winget source reset --force' (elevated) and re-run."
        exit 1
    }
    Write-Ok "winget source verified (cdn.winget.microsoft.com)"
}

function Install-WingetApp {
    param(
        [string]$Id,
        [string]$DisplayName
    )
    winget list --id $Id --exact --accept-source-agreements *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "$DisplayName already installed"
        return
    }

    Write-Info "Installing $DisplayName via winget (user scope)..."
    $output = winget install --id $Id --exact --silent --source winget `
        --accept-package-agreements --accept-source-agreements --scope user 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        if ($output -match 'No applicable installer') {
            Write-Warn "$DisplayName has no per-user installer — installing machine-wide instead (may prompt for elevation)."
            winget install --id $Id --exact --silent --source winget `
                --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) {
                Write-Err "$DisplayName machine-wide install failed (exit $LASTEXITCODE)"
                return
            }
        } else {
            Write-Err "$DisplayName install failed (exit $LASTEXITCODE):"
            Write-Host $output.Trim()
            return
        }
    }
    Update-SessionPath
    Write-Ok "$DisplayName installed"
}
#EndRegion

#Region Steps
function Install-Git {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Ok "Git already installed ($(git --version))"
        return
    }
    Write-Info "Installing Git via winget..."
    winget install --id Git.Git --silent --source winget --accept-package-agreements --accept-source-agreements
    Update-SessionPath
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Ok "Git installed ($(git --version))"
    } else {
        Write-Warn "Git installed but not yet in PATH — git commands will work after you restart your terminal."
    }
}

function Install-NerdFont {
    $FontDest   = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
    $RegPath    = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
    $MarkerFont = Join-Path $FontDest "JetBrainsMonoNerdFont-Regular.ttf"

    if (Test-Path $MarkerFont) {
        Write-Ok "JetBrains Mono Nerd Font already installed"
        return
    }

    # Pinned release + checksum: verify the download before extracting anything.
    # To bump: update both values from https://github.com/ryanoasis/nerd-fonts/releases
    # (the SHA-256.txt asset lists the hash for JetBrainsMono.zip).
    $FontVersion = 'v3.4.0'
    $FontSha256  = '76F05FF3ACE48A464A6CA57977998784FF7BDBB65A6D915D7E401CD3927C493C'
    $FontZipUrl  = "https://github.com/ryanoasis/nerd-fonts/releases/download/$FontVersion/JetBrainsMono.zip"

    # Resolve %TEMP% to its long form: Windows hands out an 8.3 short path
    # (e.g. C:\Users\FIRSTN~1.LAS\...) for some usernames, and the short form
    # doesn't resolve reliably in every cmdlet.
    $TempBase = (Get-Item -LiteralPath $env:TEMP).FullName
    $TempZip  = Join-Path $TempBase "JetBrainsMono.zip"
    $TempDir  = Join-Path $TempBase "JetBrainsMonoFonts"

    try {
        Write-Info "Downloading JetBrainsMono Nerd Font $FontVersion from NerdFonts releases..."
        Invoke-WebRequest -Uri $FontZipUrl -OutFile $TempZip -UseBasicParsing

        $actualSha256 = (Get-FileHash $TempZip -Algorithm SHA256).Hash
        if ($actualSha256 -ne $FontSha256) {
            Write-Err "Checksum mismatch for JetBrainsMono.zip"
            Write-Err "  expected: $FontSha256"
            Write-Err "  actual:   $actualSha256"
            throw "Nerd Font download failed SHA256 verification — aborting."
        }
        Write-Ok "SHA256 checksum verified"

        Write-Info "Extracting..."
        if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force }
        Expand-Archive -Path $TempZip -DestinationPath $TempDir -Force

        $ttfFiles = Get-ChildItem -Path $TempDir -Filter "JetBrainsMonoNerdFont*.ttf" -Recurse
        Write-Info "Installing $($ttfFiles.Count) font files (per-user, no admin required)..."
        New-Item -ItemType Directory -Force -Path $FontDest | Out-Null

        foreach ($ttf in $ttfFiles) {
            $destFile = Join-Path $FontDest $ttf.Name
            Copy-Item -Path $ttf.FullName -Destination $destFile -Force

            # Register in per-user font registry so apps see it without admin
            $displayName = [System.IO.Path]::GetFileNameWithoutExtension($ttf.Name) + " (TrueType)"
            Set-ItemProperty -Path $RegPath -Name $displayName -Value $destFile -Type String -Force
        }

        Write-Ok "Installed $($ttfFiles.Count) font files → $FontDest"
        Write-Ok "Registered $($ttfFiles.Count) fonts in $RegPath (per-user)"
    } finally {
        # Temp cleanup must never fail the install
        if (Test-Path $TempZip) { Remove-Item $TempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# StrictMode-safe helper: does this (possibly missing) object have property $Name?
# Use the Properties indexer, not `.Properties.Name -contains` — under
# `Set-StrictMode -Version Latest`, member-enumerating `.Name` over an empty
# member collection throws "The property 'Name' cannot be found on this object".
function Test-JsonProperty {
    param($Object, [string]$Name)
    return ($null -ne $Object) -and ($null -ne $Object.PSObject.Properties[$Name])
}

function Set-TerminalConfig {
    # Deterministic GUID of the Windows.Terminal.PowershellCore (PS7) profile —
    # identical on every machine, so hardcoding it is safe.
    $Ps7Guid  = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
    $FontFace = 'JetBrainsMono Nerd Font'

    # First existing of: Store stable, Store preview, unpackaged install.
    $candidates = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    )
    $settingsPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $settingsPath) {
        Write-Warn "Windows Terminal settings.json not found — is Terminal installed and launched once? Skipping."
        return
    }

    # Parse defensively: never risk corrupting a file we can't read back.
    try {
        $json = Get-Content $settingsPath -Raw | ConvertFrom-Json
    } catch {
        Write-Warn "Could not parse $settingsPath (comments or invalid JSON?) — skipping to avoid corrupting it."
        return
    }

    $backup = "$settingsPath.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Copy-Item $settingsPath $backup
    Write-Info "Backed up Terminal settings → $backup"

    # ── defaultProfile → PowerShell 7 ────────────────────────────────────────
    $curDefault = if (Test-JsonProperty $json 'defaultProfile') { $json.defaultProfile } else { $null }
    if ($curDefault -eq $Ps7Guid) {
        Write-Ok "Default profile: PowerShell 7 (already set)"
    } else {
        if (Test-JsonProperty $json 'defaultProfile') {
            $json.defaultProfile = $Ps7Guid
        } else {
            $json | Add-Member -NotePropertyName defaultProfile -NotePropertyValue $Ps7Guid
        }
        if ($curDefault) { Write-Ok "Default profile: PowerShell 7 (was: $curDefault)" }
        else             { Write-Ok "Default profile: PowerShell 7" }
    }

    # ── profiles.defaults.font.face → Nerd Font ──────────────────────────────
    # Create any missing intermediate objects (StrictMode forbids reading them).
    if (-not (Test-JsonProperty $json 'profiles')) {
        $json | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{})
    }
    if (-not (Test-JsonProperty $json.profiles 'defaults')) {
        $json.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{})
    }
    if (-not (Test-JsonProperty $json.profiles.defaults 'font')) {
        $json.profiles.defaults | Add-Member -NotePropertyName font -NotePropertyValue ([pscustomobject]@{})
    }
    $curFace = if (Test-JsonProperty $json.profiles.defaults.font 'face') { $json.profiles.defaults.font.face } else { $null }
    if ($curFace -eq $FontFace) {
        Write-Ok "Default font face: $FontFace (already set)"
    } else {
        if (Test-JsonProperty $json.profiles.defaults.font 'face') {
            $json.profiles.defaults.font.face = $FontFace
        } else {
            $json.profiles.defaults.font | Add-Member -NotePropertyName face -NotePropertyValue $FontFace
        }
        if ($curFace) { Write-Ok "Default font face: $FontFace (was: $curFace)" }
        else          { Write-Ok "Default font face: $FontFace" }
    }

    # PS7's utf8 encoding is BOM-less; a BOM would break Windows Terminal.
    $json | ConvertTo-Json -Depth 32 | Set-Content $settingsPath -Encoding utf8

    # Post-write validation: re-parse, and restore the backup if we broke it.
    try {
        Get-Content $settingsPath -Raw | ConvertFrom-Json | Out-Null
        Write-Ok "Windows Terminal settings updated → $settingsPath"
    } catch {
        Copy-Item $backup $settingsPath -Force
        Write-Err "Post-write validation failed — restored backup. Terminal settings left unchanged."
    }
}

function Install-Starship {
    if (Get-Command starship -ErrorAction SilentlyContinue) {
        Write-Ok "Starship already installed ($(starship --version | Select-Object -First 1))"
        return
    }
    Write-Info "Installing Starship via winget..."
    Write-Warn "Starship installs machine-wide (winget MSI) — Windows will show a one-time elevation (UAC) prompt."
    winget install --id Starship.Starship --silent --source winget --accept-package-agreements --accept-source-agreements
    Update-SessionPath
    Write-Ok "Starship installed"
}

function Set-StarshipConfig {
    $StarshipSrc  = Join-Path $ScriptDir "dotfiles\starship.toml"
    $StarshipDest = Join-Path $env:USERPROFILE ".config\starship.toml"

    if (-not (Test-Path $StarshipSrc)) {
        Write-Err "starship.toml not found at $StarshipSrc"
        exit 1
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $StarshipDest) | Out-Null

    $needsCopy = $true
    if (Test-Path $StarshipDest) {
        $srcHash  = (Get-FileHash $StarshipSrc  -Algorithm SHA256).Hash
        $destHash = (Get-FileHash $StarshipDest -Algorithm SHA256).Hash
        if ($srcHash -eq $destHash) {
            Write-Ok "starship.toml already up to date"
            $needsCopy = $false
        } else {
            $backup = "$StarshipDest.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
            Write-Info "Backing up existing starship.toml → $backup"
            Move-Item $StarshipDest $backup
        }
    }

    if ($needsCopy) {
        Copy-Item $StarshipSrc $StarshipDest
        Write-Ok "starship.toml copied to $StarshipDest"
    }
}

function Install-PSReadLine {
    $rlVersion = (Get-Module PSReadLine -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version
    if ($rlVersion -ge [version]"2.2") {
        Write-Ok "PSReadLine $rlVersion already installed"
        return
    }
    Write-Info "Installing PSReadLine 2.2+..."
    Install-Module PSReadLine -Scope CurrentUser -Force -SkipPublisherCheck
    Write-Ok "PSReadLine installed"
}

function Set-PowerShellProfile {
    $ProfileDir = Split-Path $PROFILE
    if (-not (Test-Path $ProfileDir)) {
        New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null
    }
    if (-not (Test-Path $PROFILE)) {
        New-Item -ItemType File -Force -Path $PROFILE | Out-Null
    }

    $block = @'
# >>> bootstrap >>>
Import-Module PSReadLine
Set-PSReadLineOption -PredictionSource HistoryAndPlugin
Set-PSReadLineOption -PredictionViewStyle ListView
Set-PSReadLineOption -EditMode Windows
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
Set-PSReadLineKeyHandler -Key UpArrow -Function PreviousHistory
Set-PSReadLineKeyHandler -Key DownArrow -Function NextHistory
Invoke-Expression (& starship init powershell)
# <<< bootstrap <<<
'@

    $profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
    if ($null -eq $profileContent) { $profileContent = "" }

    if ($profileContent -match '# >>> bootstrap >>>') {
        # Idempotent replace: swap out the existing sentinel block
        $updated = $profileContent -replace '(?s)# >>> bootstrap >>>.*?# <<< bootstrap <<<', $block.Trim()
        Set-Content $PROFILE $updated -NoNewline
        Write-Ok "Profile bootstrap block updated → $PROFILE"
    } else {
        Add-Content $PROFILE "`n$block"
        Write-Ok "Profile bootstrap block added → $PROFILE"
    }
}

# Announce every setting as it's applied: current value shown when overwriting.
function Set-GitSetting {
    param([string]$Key, [string]$Value, [string]$Description)
    $current = git config --global --get $Key 2>$null
    if ($current -eq $Value) {
        Write-Ok "${Description}: $Value (already set)"
    } else {
        git config --global $Key $Value
        if ($current) {
            Write-Ok "${Description}: $Value (was: $current)"
        } else {
            Write-Ok "${Description}: $Value"
        }
    }
}

function Set-GitConfig {
    if ($script:GitName) {
        if (-not (Test-PersonName $script:GitName)) { throw "Invalid git user.name — refusing to pass to git config." }
        git config --global user.name $script:GitName
        Write-Ok "Git user.name set to: $($script:GitName)"
    } elseif ($script:GitNameAlreadySet) {
        Write-Ok "Git user.name already set: $($script:GitNameAlreadySet)"
    } else {
        Write-Warn "Skipped user.name — no name entered"
    }

    if ($script:GitEmail) {
        if (-not (Test-EmailAddress $script:GitEmail)) { throw "Invalid git user.email — refusing to pass to git config." }
        git config --global user.email $script:GitEmail
        Write-Ok "Git user.email set to: $($script:GitEmail)"
    } elseif ($script:GitEmailAlreadySet) {
        Write-Ok "Git user.email already set: $($script:GitEmailAlreadySet)"
    } else {
        Write-Warn "Skipped user.email — no email entered"
    }

    Set-GitSetting init.defaultBranch main "Default branch for new repos"
    Set-GitSetting core.autocrlf true "Line-ending conversion (core.autocrlf)"
    Set-GitSetting credential.helper manager "Credential helper"
    Set-GitSetting core.editor vim "Default editor"
    Set-GitSetting alias.st status "Alias 'git st'"
    Set-GitSetting alias.co checkout "Alias 'git co'"
    Set-GitSetting alias.br branch "Alias 'git br'"
    Set-GitSetting alias.lg "log --oneline --graph --decorate --all" "Alias 'git lg'"
}

function New-SshKey {
    if (Test-Path $script:SshKeyPath) {
        Write-Ok "SSH key already exists: $($script:SshKeyPath)"
        return
    }
    if (-not $script:SshEmail) {
        Write-Warn "Skipped — no email entered"
        return
    }
    if (-not (Test-EmailAddress $script:SshEmail)) { throw "Invalid SSH email — refusing to pass to ssh-keygen." }

    $passphrase = ''
    if ($script:SshPassphrase -and $script:SshPassphrase.Length -gt 0) {
        $passphrase = [System.Net.NetworkCredential]::new('', $script:SshPassphrase).Password
    }

    $sshDir = Split-Path $script:SshKeyPath
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    ssh-keygen -t ed25519 -C $script:SshEmail -f $script:SshKeyPath -N $passphrase
    Write-Ok "SSH key generated: $($script:SshKeyPath)"
    Write-Info "Public key:"
    Get-Content "$($script:SshKeyPath).pub"
}
#EndRegion

#Region Menu
function Show-SelectionMenu {
    param([array]$Steps)

    $optional = @($Steps | Where-Object { -not $_.Mandatory })
    $selected = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($s in $optional) {
        if ($s.Default) { [void]$selected.Add($s.Key) }
    }

    $notice = @()
    while ($true) {
        # Redraw in place: clear + banner each pass so toggles update the
        # checkboxes instead of stacking a new copy of the menu
        Show-Banner
        Write-Section "Setup selection"
        Write-Host ""
        Write-Host "  Always runs:" -ForegroundColor Blue
        foreach ($s in ($Steps | Where-Object { $_.Mandatory })) {
            Write-Host "      • $($s.Label)"
        }
        Write-Host ""
        Write-Host "  Optional (toggle by number):" -ForegroundColor Blue
        for ($i = 0; $i -lt $optional.Count; $i++) {
            $mark = if ($selected.Contains($optional[$i].Key)) { '[x]' } else { '[ ]' }
            Write-Host ("  {0,2}) {1} {2}" -f ($i + 1), $mark, $optional[$i].Label)
        }
        Write-Host ""
        foreach ($n in $notice) { Write-Warn $n }
        $notice = @()
        $answer = (Read-Host "  Numbers to toggle (space-separated), 'a'=all, 'n'=none, Enter/'d'=done").Trim()

        # Comma operator: stop PowerShell unrolling the HashSet (an empty or
        # single-element set would otherwise come back as $null / a string)
        if ($answer -eq '' -or $answer -eq 'd') { return ,$selected }
        if ($answer -eq 'a') {
            foreach ($s in $optional) { [void]$selected.Add($s.Key) }
            continue
        }
        if ($answer -eq 'n') {
            $selected.Clear()
            continue
        }
        foreach ($tok in ($answer -split '\s+')) {
            if ($tok -match '^\d+$' -and [int]$tok -ge 1 -and [int]$tok -le $optional.Count) {
                $key = $optional[[int]$tok - 1].Key
                if (-not $selected.Remove($key)) { [void]$selected.Add($key) }
            } else {
                # Buffered and shown after the redraw, so the clear doesn't eat it
                $notice += "Ignored: $tok"
            }
        }
    }
}
#EndRegion

$ScriptDir = $PSScriptRoot

#Region Main

Show-Banner

# ── Prerequisites ─────────────────────────────────────────────────────────────
Write-Section "Prerequisites"
Test-WingetPrerequisite

# ── Step registry ─────────────────────────────────────────────────────────────
$Steps = @(
    @{ Key = 'git';       Label = 'Git';                          Mandatory = $true;  Default = $true;  Action = { Install-Git } }
    @{ Key = 'font';      Label = 'JetBrains Mono Nerd Font';     Mandatory = $false; Default = $true;  Action = { Install-NerdFont } }
    @{ Key = 'terminal';  Label = 'Windows Terminal settings';    Mandatory = $false; Default = $true;  Action = { Set-TerminalConfig } }
    @{ Key = 'starship';  Label = 'Starship prompt';              Mandatory = $true;  Default = $true;  Action = { Install-Starship } }
    @{ Key = 'starcfg';   Label = 'Starship config';              Mandatory = $true;  Default = $true;  Action = { Set-StarshipConfig } }
    @{ Key = 'psrl';      Label = 'PSReadLine';                   Mandatory = $true;  Default = $true;  Action = { Install-PSReadLine } }
    @{ Key = 'profile';   Label = 'PowerShell profile';           Mandatory = $true;  Default = $true;  Action = { Set-PowerShellProfile } }
    @{ Key = 'gitcfg';    Label = 'Git configuration';            Mandatory = $true;  Default = $true;  Action = { Set-GitConfig } }
    @{ Key = 'ssh';       Label = 'SSH key (ed25519)';            Mandatory = $false; Default = $true;  Action = { New-SshKey } }
    @{ Key = 'vscode';    Label = 'VS Code';                      Mandatory = $false; Default = $false; Action = { Install-WingetApp 'Microsoft.VisualStudioCode' 'VS Code' } }
    @{ Key = 'claude';    Label = 'Claude desktop';               Mandatory = $false; Default = $false; Action = { Install-WingetApp 'Anthropic.Claude' 'Claude' } }
    @{ Key = 'obsidian';  Label = 'Obsidian';                     Mandatory = $false; Default = $false; Action = { Install-WingetApp 'Obsidian.Obsidian' 'Obsidian' } }
    @{ Key = 'ahk';       Label = 'AutoHotkey';                   Mandatory = $false; Default = $false; Action = { Install-WingetApp 'AutoHotkey.AutoHotkey' 'AutoHotkey' } }
    @{ Key = '7zip';      Label = '7-Zip (machine-wide)';         Mandatory = $false; Default = $false; Action = { Install-WingetApp '7zip.7zip' '7-Zip' } }
    @{ Key = 'flameshot'; Label = 'Flameshot (machine-wide)';     Mandatory = $false; Default = $false; Action = { Install-WingetApp 'Flameshot.Flameshot' 'Flameshot' } }
)

# ── Selection menu (prints its own section header on each redraw) ────────────
$Selected = Show-SelectionMenu -Steps $Steps

# ── Upfront input (validated here, before anything runs) ─────────────────────
Write-Section "Configuration input"

$script:GitName            = ''
$script:GitEmail           = ''
$script:GitNameAlreadySet  = $null
$script:GitEmailAlreadySet = $null
if (Get-Command git -ErrorAction SilentlyContinue) {
    $script:GitNameAlreadySet  = git config --global user.name 2>$null
    $script:GitEmailAlreadySet = git config --global user.email 2>$null
}

if ($script:GitNameAlreadySet) {
    Write-Ok "Git user.name already set: $($script:GitNameAlreadySet)"
} else {
    $script:GitName = Read-ValidatedInput -Prompt "  Git user.name (e.g. Your Name; blank to skip)" `
        -Validator ${function:Test-PersonName} -Hint "Letters, numbers, spaces, . ' - only (max 64 chars)." -AllowBlank
}

if ($script:GitEmailAlreadySet) {
    Write-Ok "Git user.email already set: $($script:GitEmailAlreadySet)"
} else {
    $script:GitEmail = Read-ValidatedInput -Prompt "  Git user.email (e.g. you@example.com; blank to skip)" `
        -Validator ${function:Test-EmailAddress} -Hint "Expected form: user@example.com" -AllowBlank
}

$script:SshKeyPath    = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
$script:SshEmail      = ''
$script:SshPassphrase = $null
if ($Selected.Contains('ssh') -and -not (Test-Path $script:SshKeyPath)) {
    $script:SshEmail = Read-ValidatedInput -Prompt "  Email for SSH key (blank to skip)" `
        -Validator ${function:Test-EmailAddress} -Hint "Expected form: user@example.com" -AllowBlank
    if ($script:SshEmail) {
        $script:SshPassphrase = Read-Host "  SSH key passphrase (blank for none)" -AsSecureString
        if ($script:SshPassphrase.Length -eq 0) {
            Write-Warn "No passphrase — the private key will be stored unencrypted on disk."
        }
    }
}

# ── Run selected steps ────────────────────────────────────────────────────────
# Fresh screen for the unattended run; the step log scrolls from here
Show-Banner
foreach ($step in $Steps) {
    if ($step.Mandatory -or $Selected.Contains($step.Key)) {
        Write-Section $step.Label
        & $step.Action
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Section "Setup Complete"
Write-Host ""
Write-Ok "PowerShell 7 (already provisioned at launch)"
foreach ($step in $Steps) {
    if ($step.Mandatory -or $Selected.Contains($step.Key)) {
        Write-Ok $step.Label
    }
}
Write-Host ""
Write-Info "Open a new pwsh terminal to activate Starship and PSReadLine settings."
if ($Selected.Contains('terminal')) {
    Write-Info "Restart Windows Terminal to apply the new font and default profile."
} elseif ($Selected.Contains('font')) {
    Write-Info "Set font in Windows Terminal: Settings → Profile → Appearance → Font face → JetBrainsMono Nerd Font"
}

#EndRegion
