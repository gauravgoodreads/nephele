# Windows entry point: runs scripts/kind-up.sh with Git Bash.
#   powershell -ExecutionPolicy Bypass -File scripts\kind-up.ps1
#   $env:MONITORING = "0"; powershell -ExecutionPolicy Bypass -File scripts\kind-up.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$bash = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bash) { throw "Git Bash not found. Install Git for Windows, or run scripts/kind-up.sh from WSL." }
& $bash "$root/scripts/kind-up.sh"
exit $LASTEXITCODE
