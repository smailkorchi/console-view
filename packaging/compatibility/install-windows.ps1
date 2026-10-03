#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '1.0.0',
    [switch]$AllowArm64Emulation
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or [Environment]::OSVersion.Version.Major -lt 10) {
    throw 'Console View requires Windows10 or newer.'
}
$nativeArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$arch = switch ($nativeArch.ToUpperInvariant()) {
    'AMD64' { 'x64' }
    'X86' { 'x86' }
    'ARM64' {
        if (-not $AllowArm64Emulation -or [Environment]::OSVersion.Version.Build -lt 22000) {
            throw 'A native ARM64 build is not available. On Windows11 ARM64, use -AllowArm64Emulation to choose the x64 build; capture hardware is unverified under emulation.'
        }
        'x64'
    }
    default { throw "Unsupported Windows processor: $nativeArch" }
}
$base = "https://github.com/smailkorchi/console-view/releases/download/v$Version-compatibility"
$asset = "Console-View-$Version-Windows-$arch-Setup.exe"
$work = Join-Path ([IO.Path]::GetTempPath()) ('console-view-install-' + [Guid]::NewGuid().ToString('N'))
$previousProtocol = [Net.ServicePointManager]::SecurityProtocol
try {
    [Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory $work | Out-Null
    $checksumFile = Join-Path $work 'SHA256SUMS.txt'
    Invoke-WebRequest "$base/SHA256SUMS.txt" -UseBasicParsing -OutFile $checksumFile
    $checksums = Get-Content $checksumFile -Raw
    $matches = @($checksums -split "`n" | Where-Object { $_.TrimEnd("`r") -match ('^[0-9a-fA-F]{64}  ' + [regex]::Escape($asset) + '$') })
    if ($matches.Count -ne 1) { throw "Release checksum is missing or ambiguous for $asset" }
    $expected = $matches[0].Substring(0, 64).ToLowerInvariant()
    $installer = Join-Path $work $asset
    Invoke-WebRequest "$base/$asset" -UseBasicParsing -OutFile $installer
    $actual = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw 'Download checksum mismatch. Nothing was installed.' }
    Write-Host "Verified $asset. Installing for the current user."
    $log = Join-Path $env:TEMP 'console-view-install.log'
    $process = Start-Process $installer -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',('/LOG="' + $log + '"') -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Installation failed ($($process.ExitCode)). Log: $log" }
    $app = Join-Path $env:LOCALAPPDATA 'Programs/Console View/consoleview.exe'
    if (-not (Test-Path $app)) { throw "Installation did not create $app. Log: $log" }
    Write-Host 'Console View is installed. Open it from the Start menu. Uninstall through Windows Settings > Apps.'
} finally {
    [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
}
