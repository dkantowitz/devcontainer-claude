#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Host-side utilities for managing the Claude Code devcontainer.

.DESCRIPTION
    Single entry point for all host-side devcontainer operations.
    Consolidates check-host.ps1, firewall-toggle.ps1, and claude-login.ps1.

.PARAMETER Command
    Subcommand to run:
      init            - Prepare host environment before container build
                        (called automatically by devcontainer.json initializeCommand)
      toggle-firewall - Toggle firewall.conf between enforce and bypass
                        Pass a container name to toggle per-container override.
                        Use -Delete <name> to remove a per-container override.
      login           - Run claude /login on the host and copy credentials to dotclaude

.EXAMPLE
    # Called automatically by devcontainer.json:
    powershell -ExecutionPolicy Bypass -File .devcontainer/devcontainer-utils.ps1 init

    # Manual user commands:
    powershell -File .devcontainer/devcontainer-utils.ps1 toggle-firewall
    powershell -File .devcontainer/devcontainer-utils.ps1 toggle-firewall mycontainer
    powershell -File .devcontainer/devcontainer-utils.ps1 toggle-firewall -Delete mycontainer
    powershell -File .devcontainer/devcontainer-utils.ps1 login
#>

param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('init', 'toggle-firewall', 'login')]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$ContainerName,

    [switch]$Delete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DotClaude = "$env:USERPROFILE\dotclaude"

# ── Subcommand: init ──────────────────────────────────────────────────────────
# Formerly check-host.ps1. Called by devcontainer.json initializeCommand.
# Creates required dotclaude/ directories and files, ensures firewall.conf
# defaults to 'enforce', and writes .env from claude.token if present.

function Invoke-Init {
    $requiredFiles = @(
        "$DotClaude\.credentials.json",
        "$DotClaude\settings.json",
        "$DotClaude\history.jsonl",
        "$DotClaude\CLAUDE.md"
    )

    # Derive project name from the workspace folder (parent of .devcontainer/)
    $WorkspaceName = Split-Path -Leaf (Split-Path -Parent $PSScriptRoot)

    $requiredDirs = @(
        "$DotClaude\commands",
        "$DotClaude\firewall",
        "$DotClaude\plugins",
        "$DotClaude\projects",
        "$DotClaude\projects\$WorkspaceName",
        "$DotClaude\projects\$WorkspaceName\memory",
        "$DotClaude\ssh"
    )

    foreach ($d in $requiredDirs) {
        if (-not (Test-Path $d -PathType Container)) {
            Write-Host "Creating directory: $d"
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }

    foreach ($f in $requiredFiles) {
        if (-not (Test-Path $f -PathType Leaf)) {
            Write-Host "Creating empty file: $f"
            New-Item -ItemType File -Path $f -Force | Out-Null
        }
    }

    # Ensure firewall/firewall.conf has a valid default
    $firewallConf = "$DotClaude\firewall\firewall.conf"
    $content = (Get-Content $firewallConf -Raw -ErrorAction SilentlyContinue) -replace '\s', ''
    if ($content -notin @('enforce', 'bypass')) {
        Write-Host "Setting firewall.conf to 'enforce' (default)"
        Set-Content -Path $firewallConf -Value "enforce" -NoNewline
    }

    # ── Per-container firewall override ──────────────────────────────────────
    # Derive container name from the workspace folder (the directory containing
    # .devcontainer/).  If a <name>.conf exists in the firewall directory, it
    # overrides the global firewall.conf for this container only.
    $containerName = Split-Path -Leaf (Split-Path -Parent $PSScriptRoot)
    $containerConf = "$DotClaude\firewall\$containerName.conf"
    if (Test-Path $containerConf -PathType Leaf) {
        $overrideMode = (Get-Content $containerConf -Raw) -replace '\s', ''
        Write-Host "Per-container firewall override: $containerConf = $overrideMode"
    }
    else {
        $globalMode = (Get-Content $firewallConf -Raw -ErrorAction SilentlyContinue) -replace '\s', ''
        Write-Host "Firewall: using global firewall.conf ($globalMode) - no per-container override for '$containerName'"
    }

    # Ensure firewall/allowlist exists (host-side user allowlist, merged with
    # per-project .devcontainer/allowlist by init-firewall.sh at container startup).
    $hostAllowlist = "$DotClaude\firewall\allowlist"
    if (-not (Test-Path $hostAllowlist -PathType Leaf)) {
        Write-Host "Creating host allowlist: $hostAllowlist"
        $header = @(
            "# Host-side allowlist for init-firewall.sh",
            "# Merged with per-project .devcontainer/allowlist at container startup.",
            "# Add one entry per line. Supports plain domains, IP addresses, and CIDR",
            "# ranges. Any github.com or githubusercontent.com entry triggers a bulk",
            "# CIDR fetch from api.github.com/meta instead of plain DNS resolution.",
            "# Blank lines and lines starting with '#' are ignored.",
            "# Failures are non-fatal (WARNING only).",
            ""
        ) -join "`n"
        Set-Content -Path $hostAllowlist -Value $header -NoNewline
    }

    # ── Token file → Docker .env ──────────────────────────────────────────────
    $envFile = Join-Path $PSScriptRoot ".env"
    $tokenFile = "$DotClaude\claude.token"
    $token = if (Test-Path $tokenFile -PathType Leaf) {
        (Get-Content $tokenFile -Raw -ErrorAction SilentlyContinue) -replace '\s', ''
    }
    else { '' }

    if ($token) {
        Set-Content -Path $envFile -Value "CLAUDE_CODE_OAUTH_TOKEN=$token`n" -NoNewline
        Write-Host "claude.token loaded into .devcontainer/.env"
    }
    else {
        Set-Content -Path $envFile -Value "" -NoNewline
    }

    Write-Host "Host environment OK"
}

# ── Subcommand: toggle-firewall ───────────────────────────────────────────────
# Formerly firewall-toggle.ps1. Toggles firewall config between enforce and bypass.
# Accepts an optional container name for per-container overrides.
# Use -Delete <name> to remove a per-container override (revert to global).
# Run manually from a host-side PowerShell terminal, then rebuild the container.

function Invoke-ToggleFirewall {
    param(
        [string]$Name,
        [switch]$Remove
    )

    $firewallDir = "$DotClaude\firewall"

    if ($Name) {
        $conf = "$firewallDir\$Name.conf"
        $label = "per-container '$Name'"
    }
    else {
        $conf = "$firewallDir\firewall.conf"
        $label = "global"
    }

    # Handle -Delete: remove per-container override
    if ($Remove) {
        if (-not $Name) {
            Write-Host "ERROR: -Delete requires a container name."
            Write-Host "Usage: devcontainer-utils.ps1 toggle-firewall -Delete <container-name>"
            exit 1
        }
        if (Test-Path $conf) {
            Remove-Item $conf
            Write-Host "Deleted $label override: $conf"
            Write-Host "Container '$Name' will use global firewall.conf on next rebuild."
        }
        else {
            Write-Host "No $label override exists ($conf)"
        }
        return
    }

    # Create the file if it doesn't exist (default to enforce)
    if (-not (Test-Path $conf)) {
        Set-Content -Path $conf -Value "enforce" -NoNewline
        if ($Name) {
            Write-Host "Created $label override: $conf (enforce)"
        }
    }

    $current = (Get-Content $conf -Raw).Trim()

    if ($current -eq "bypass") {
        Set-Content -Path $conf -Value "enforce" -NoNewline
        Write-Host "Firewall ($label): bypass -> ENFORCE"
        Write-Host "  File: $conf"
        Write-Host "Rebuild the container to apply."
    }
    elseif ($current -eq "enforce") {
        Set-Content -Path $conf -Value "bypass" -NoNewline
        Write-Host "Firewall ($label): enforce -> BYPASS"
        Write-Host "  File: $conf"
        Write-Host "Rebuild the container to apply."
    }
    else {
        Write-Host "Unknown value '$current' in $conf - resetting to 'enforce'"
        Set-Content -Path $conf -Value "enforce" -NoNewline
    }
}

# ── Subcommand: login ─────────────────────────────────────────────────────────
# Formerly claude-login.ps1. Runs claude /login on the host and copies the
# resulting credentials into dotclaude/ for use by the devcontainer.

function Invoke-Login {
    $claudeCredentials = Join-Path $env:USERPROFILE ".claude" ".credentials.json"
    $dotclaudeCredentials = Join-Path $DotClaude ".credentials.json"

    # Ensure target directory exists
    if (-not (Test-Path $DotClaude)) {
        New-Item -ItemType Directory -Path $DotClaude | Out-Null
        Write-Host "Created $DotClaude"
    }

    # Run Claude login
    Write-Host "Starting Claude login..."
    claude /login
    if ($LASTEXITCODE -ne 0) {
        Write-Error "claude /login failed with exit code $LASTEXITCODE"
        exit 1
    }

    # Verify credentials were written
    if (-not (Test-Path $claudeCredentials)) {
        # Fallback: AppData location used by some installs
        $fallback = Join-Path $env:APPDATA "Claude" ".credentials.json"
        if (Test-Path $fallback) {
            $claudeCredentials = $fallback
            Write-Host "Found credentials at fallback path: $claudeCredentials"
        }
        else {
            Write-Error "Login appeared to succeed but credentials not found at:`n  $claudeCredentials`n  $fallback"
            exit 1
        }
    }

    Copy-Item -Path $claudeCredentials -Destination $dotclaudeCredentials -Force
    Write-Host "Credentials copied to $dotclaudeCredentials"
    Write-Host "Done. Restart your devcontainer to pick up the new credentials."
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

switch ($Command) {
    'init' { Invoke-Init }
    'toggle-firewall' { Invoke-ToggleFirewall -Name $ContainerName -Remove:$Delete }
    'login' { Invoke-Login }
}
