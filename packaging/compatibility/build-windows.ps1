param(
    [Parameter(Mandatory=$true)][ValidateSet('x86','x64')][string]$Arch,
    [Parameter(Mandatory=$true)][string]$QtDir,
    [Parameter(Mandatory=$true)][string]$InnoCompiler,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '1.0.0'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Build on Windows with Visual Studio and Qt installed.' }
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Set-Location $root
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$build = Join-Path $tempRoot ("console-view-windows-$Arch-" + [Guid]::NewGuid().ToString('N'))
$output = Join-Path $root "dist/compatibility/windows-$Arch"
$portable = Join-Path $build 'Console View'
$python = (Get-Command python).Source
New-Item -ItemType Directory -Force $build,$output,$portable | Out-Null
$cmakeArch = if ($Arch -eq 'x86') { 'Win32' } else { 'x64' }
# Qt 5.15.2's MSVC2019 SDK uses the v142 ABI; newer VC14 runtimes are compatible.
cmake -S compatibility -B "$build/cmake" -G 'Visual Studio 17 2022' -A $cmakeArch -T v142 "-DCMAKE_PREFIX_PATH=$QtDir" '-DCMAKE_SYSTEM_VERSION=10.0.19041.0'
if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed' }
cmake --build "$build/cmake" --config Release --parallel 2
if ($LASTEXITCODE -ne 0) { throw 'CMake build failed' }
$env:QT_QPA_PLATFORM = 'offscreen'
$env:PATH = "$QtDir/bin;$env:PATH"
ctest --test-dir "$build/cmake" -C Release --output-on-failure
if ($LASTEXITCODE -ne 0) { throw 'Core tests failed' }
Copy-Item "$build/cmake/Release/consoleview.exe" $portable
& "$QtDir/bin/windeployqt.exe" --release --no-compiler-runtime --no-translations --dir $portable "$portable/consoleview.exe"
if ($LASTEXITCODE -ne 0) { throw 'Qt deployment failed' }
# Camera and audio plugins are loaded dynamically and are not all inferred from imports.
foreach ($plugin in @('mediaservice/dsengine.dll','mediaservice/wmfengine.dll','audio/qtaudio_windows.dll','audio/qtaudio_wasapi.dll','platforms/qoffscreen.dll')) {
    $source = Join-Path "$QtDir/plugins" $plugin
    if (-not (Test-Path $source)) { throw "Required Qt plugin is missing: $plugin" }
    $destination = Join-Path $portable $plugin
    New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
    Copy-Item $source $destination -Force
}
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $visualStudio) { throw 'Visual Studio C++ installation not found' }
$redistRoot = Join-Path $visualStudio 'VC/Redist/MSVC'
$runtime = Join-Path $redistRoot "v143/$Arch/Microsoft.VC143.CRT"
if (-not (Test-Path $runtime)) {
    $runtime = Get-ChildItem $redistRoot -Directory -Recurse | Where-Object { $_.Name -match '^Microsoft\.VC14[023]\.CRT$' -and $_.Parent.Name -eq $Arch } | Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName
}
if (-not $runtime -or -not (Test-Path "$runtime/vcruntime140.dll")) { throw 'Redistributable VC14 runtime is missing' }
Copy-Item "$runtime/*.dll" $portable
# Windows10+ supplies UCRT. Keep VC runtime app-local; do not install system prerequisites.
Copy-Item LICENSE "$portable/LICENSE.txt"
Copy-Item packaging/compatibility/licenses $portable -Recurse
Copy-Item packaging/compatibility/THIRD-PARTY-NOTICES.txt,packaging/compatibility/QT-SOURCE-OFFER.txt,packaging/compatibility/REPLACING-QT.txt,packaging/compatibility/WINDOWS-INSTALL.txt $portable
@('[Paths]','Prefix=.','Plugins=.') | Set-Content "$portable/qt.conf" -Encoding ascii
$qtVersion = & "$QtDir/bin/qmake.exe" -query QT_VERSION
if ($qtVersion -ne '5.15.2') { throw "Unexpected Qt SDK: $qtVersion" }
$qtVersion | Set-Content "$portable/qt-runtime-version.txt" -Encoding ascii
& $python packaging/compatibility/check-windows-package.py $portable $Arch | Tee-Object "$output/binary-metadata.txt"
if ($LASTEXITCODE -ne 0) { throw 'Portable dependency check failed' }
& $python -c "from PIL import Image; Image.open('icon/icon_1024.png').save(r'$build/Installer.ico',sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])"
if ($LASTEXITCODE -ne 0) { throw 'Installer icon generation failed' }
& $InnoCompiler "/DPackageVersion=$Version" "/DPackageArch=$Arch" "/DSourceDir=$portable" "/DOutputDir=$output" "/DIconFile=$build/Installer.ico" packaging/compatibility/windows-installer.iss
if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed' }

# A deployed application must start without Qt's SDK/environment on the search path.
$env:PATH = "$env:SystemRoot/System32;$env:SystemRoot"
Remove-Item Env:QT_PLUGIN_PATH,Env:QML2_IMPORT_PATH -ErrorAction SilentlyContinue
function Test-Startup([string]$Directory, [string]$Label, [string]$Platform) {
    $env:QT_QPA_PLATFORM = $Platform
    $process = Start-Process "$Directory/consoleview.exe" -ArgumentList '--smoke-test' -PassThru -RedirectStandardOutput "$output/$Label.txt" -RedirectStandardError "$output/$Label-errors.txt"
    if (-not $process.WaitForExit(30000)) { $process.Kill(); throw "$Label timed out" }
    $process.Refresh()
    if ($process.ExitCode -ne 0) { throw "$Label failed: $($process.ExitCode)" }
    if (-not (Select-String -Path "$output/$Label.txt" -SimpleMatch 'Console View Qt startup smoke passed' -Quiet)) { throw "$Label did not report a successful Qt startup" }
}
Test-Startup $portable 'portable-windows-smoke' 'windows'
Test-Startup $portable 'portable-offscreen-smoke' 'offscreen'
$archive = Join-Path $output "Console-View-$Version-Windows-$Arch-Portable.zip"
Compress-Archive -Path $portable -DestinationPath $archive -Force
$extracted = Join-Path $build 'extracted-smoke'
Expand-Archive $archive $extracted
& $python packaging/compatibility/check-windows-package.py "$extracted/Console View" $Arch | Tee-Object "$output/extracted-metadata.txt"
if ($LASTEXITCODE -ne 0) { throw 'Extracted ZIP dependency check failed' }
Test-Startup "$extracted/Console View" 'extracted-windows-smoke' 'windows'

$setup = Join-Path $output "Console-View-$Version-Windows-$Arch-Setup.exe"
$installed = Join-Path $build 'installed-smoke'
$process = Start-Process $setup -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',('/DIR="' + $installed + '"'),('/LOG="' + "$output/installer-test.txt" + '"') -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Installer test failed: $($process.ExitCode)" }
& $python packaging/compatibility/check-windows-package.py $installed $Arch | Tee-Object "$output/installed-metadata.txt"
if ($LASTEXITCODE -ne 0) { throw 'Installed dependency check failed' }
Test-Startup $installed 'installed-windows-smoke' 'windows'
$uninstaller = Join-Path $installed 'unins000.exe'
if (-not (Test-Path $uninstaller)) { throw 'Uninstaller was not installed' }
$process = Start-Process $uninstaller -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -PassThru
if ($process.ExitCode -ne 0 -or (Test-Path "$installed/consoleview.exe")) { throw 'Uninstall did not remove the installed app' }
'PASS: isolated per-user installation, deployed startup, and uninstall.' | Set-Content "$output/install-uninstall-result.txt"
Get-ChildItem $output -File | Where-Object Extension -In '.zip','.exe' | ForEach-Object { "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(),$_.Name } | Set-Content "$output/SHA256SUMS.txt" -Encoding ascii
