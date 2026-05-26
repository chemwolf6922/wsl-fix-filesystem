<#
.SYNOPSIS
    Repair the ext4 filesystem of a broken WSL distro using a bundled helper distro.

.DESCRIPTION
    Automates the manual WSL filesystem-repair workflow:
      1. Locates the target distro's ext4.vhdx via the registry.
      2. Imports a minimal helper distro (Alpine + e2fsprogs) shipped alongside this script.
      3. Terminates the target distro and bare-mounts its VHD.
      4. Identifies the new block device inside the helper and runs `e2fsck -yfv`.
      5. Unmounts the VHD and unregisters the helper distro.

.PARAMETER DistroName
    Name of the broken WSL distro whose filesystem should be checked / repaired.

.EXAMPLE
    .\fix-filesystem.ps1 Ubuntu
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$DistroName,

    [string]$HelperDistroName = 'wsl-fixer',
    [string]$HelperTarball
)

$ErrorActionPreference = 'Stop'

# Pick the rootfs tarball matching the host CPU architecture if not overridden.
if (-not $HelperTarball) {
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'amd64' }
        'ARM64' { 'arm64' }
        default { throw "Unsupported host architecture: $($env:PROCESSOR_ARCHITECTURE)" }
    }
    $HelperTarball = Join-Path $PSScriptRoot "fixer-distro-$arch.tar.gz"
    # Backwards compatibility with single-arch local builds.
    if (-not (Test-Path -LiteralPath $HelperTarball)) {
        $legacy = Join-Path $PSScriptRoot 'fixer-distro.tar.gz'
        if (Test-Path -LiteralPath $legacy) { $HelperTarball = $legacy }
    }
}

# Self-elevate: `wsl --mount` requires administrator privileges.
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "==> Elevating to administrator..." -ForegroundColor Cyan
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { throw "Cannot self-elevate: script path unknown. Re-run from an elevated PowerShell." }
    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$scriptPath`"",
        '-DistroName', "`"$DistroName`"",
        '-HelperDistroName', "`"$HelperDistroName`"",
        '-HelperTarball', "`"$HelperTarball`""
    )
    $proc = Start-Process -FilePath 'pwsh.exe' -ArgumentList $argList -Verb RunAs -PassThru -Wait -ErrorAction SilentlyContinue
    if (-not $proc) {
        # Fall back to Windows PowerShell if pwsh is unavailable.
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -PassThru -Wait
    }
    exit $proc.ExitCode
}

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

function Invoke-Wsl {
    # Run wsl.exe and surface non-zero exit codes as terminating errors.
    $output = & wsl.exe @args
    if ($LASTEXITCODE -ne 0) {
        throw "wsl.exe $($args -join ' ') failed (exit $LASTEXITCODE): $output"
    }
    return $output
}

function Get-DistroVhd {
    param([string]$Name)
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $match = Get-ChildItem $key |
        ForEach-Object { Get-ItemProperty $_.PSPath } |
        Where-Object { $_.DistributionName -eq $Name -and $_.BasePath }
    if (-not $match) { throw "Distro '$Name' not found in registry." }
    $base = $match.BasePath -replace '^\\\\\?\\',''
    $vhd  = Join-Path $base 'ext4.vhdx'
    if (-not (Test-Path -LiteralPath $vhd)) {
        throw "VHD not found at expected path: $vhd"
    }
    return $vhd
}

function Test-DistroRegistered {
    param([string]$Name)
    # `wsl -l -q` output is UTF-16; PowerShell handles it transparently here.
    $list = & wsl.exe -l -q 2>$null
    return ($list | ForEach-Object { $_.Trim() }) -contains $Name
}

# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $HelperTarball)) {
    throw "Helper distro tarball not found: $HelperTarball"
}

Write-Step "Locating VHD for distro '$DistroName'"
$vhd = Get-DistroVhd -Name $DistroName
Write-Info $vhd

Write-Step "Terminating '$DistroName' (if running)"
& wsl.exe --terminate $DistroName 2>$null | Out-Null

$helperInstallDir = Join-Path $env:TEMP "wsl-fixer-$([guid]::NewGuid().ToString('N'))"
$mounted = $false
$imported = $false

try {
    Write-Step "Importing helper distro '$HelperDistroName'"
    if (Test-DistroRegistered -Name $HelperDistroName) {
        throw "A distro named '$HelperDistroName' is already registered. Remove it or pass -HelperDistroName."
    }
    New-Item -ItemType Directory -Path $helperInstallDir -Force | Out-Null
    Invoke-Wsl --import $HelperDistroName $helperInstallDir $HelperTarball --version 2 | Out-Null
    $imported = $true

    Write-Step "Snapshotting block devices before mount"
    $before = (Invoke-Wsl -d $HelperDistroName -u root -- sh -c "ls /dev/sd* 2>/dev/null || true") -split "`n" |
        Where-Object { $_ }

    Write-Step "Bare-mounting VHD"
    Invoke-Wsl --mount --bare --vhd $vhd | Out-Null
    $mounted = $true

    # Give the kernel a moment to enumerate the new device.
    Start-Sleep -Seconds 2

    Write-Step "Identifying new block device"
    $after = (Invoke-Wsl -d $HelperDistroName -u root -- sh -c "ls /dev/sd* 2>/dev/null || true") -split "`n" |
        Where-Object { $_ }
    $new = $after | Where-Object { $before -notcontains $_ }
    if (-not $new) { throw "Could not detect newly mounted block device. After: $($after -join ', ')" }
    if ($new.Count -gt 1) {
        Write-Info "Multiple new devices detected: $($new -join ', '). Using first."
        $new = $new[0]
    }
    Write-Info "Target device: $new"

    Write-Step "Running e2fsck on $new"
    # Stream output directly; do not use Invoke-Wsl since we want live output and
    # e2fsck returns non-zero for "errors were fixed" which is success for us.
    & wsl.exe -d $HelperDistroName -u root -- e2fsck -yfv $new
    $fsckExit = $LASTEXITCODE
    Write-Info "e2fsck exit code: $fsckExit"
    # e2fsck exit codes: 0=clean, 1=errors corrected, 2=reboot needed.
    # 4+ = uncorrected / operational errors.
    if ($fsckExit -ge 4) {
        Write-Warning "e2fsck reported uncorrected errors (exit $fsckExit). Filesystem may still be damaged."
    }
}
finally {
    if ($mounted) {
        Write-Step "Unmounting VHD"
        & wsl.exe --unmount $vhd 2>&1 | Out-Null
    }
    if ($imported) {
        Write-Step "Removing helper distro"
        & wsl.exe --unregister $HelperDistroName 2>&1 | Out-Null
    }
    if (Test-Path -LiteralPath $helperInstallDir) {
        Remove-Item -LiteralPath $helperInstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Step "Done."
