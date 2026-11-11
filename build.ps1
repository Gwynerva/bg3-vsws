# Собирает мод в .pak и кладёт его в папку модов игры.
#   .\build.ps1            собрать и установить
#   .\build.ps1 -NoInstall только собрать в build\
param([switch]$NoInstall)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$env:DOTNET_ROOT = Join-Path $root 'tools\dotnet'
$divine = Join-Path $root 'tools\lslib\Packed\Tools\Divine.exe'
$source = Join-Path $root 'mod'
$pak = Join-Path $root 'build\Gwynerva_VisibleShieldsAndWeaponSets.pak'

New-Item -ItemType Directory -Force (Split-Path $pak) | Out-Null
& $divine -g bg3 -a create-package -s $source -d $pak -c lz4 | Select-Object -Last 1
if (-not (Test-Path $pak)) { throw "Build failed: $pak was not created" }

if (-not $NoInstall) {
    $mods = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Mods"
    Copy-Item $pak $mods -Force
    "Installed: $mods\Gwynerva_VisibleShieldsAndWeaponSets.pak"
}
