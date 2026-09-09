param(
    [string]$Destination = 'C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\EllesmereUICooldownManager'
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'EllesmereUICooldownManager'
$toc = Join-Path $source 'EllesmereUICooldownManager.toc'

if (-not (Test-Path -LiteralPath $toc)) {
    throw "Source validation failed: $toc was not found."
}
if ((Split-Path -Leaf $Destination) -ne 'EllesmereUICooldownManager') {
    throw "Destination must end in EllesmereUICooldownManager: $Destination"
}

New-Item -ItemType Directory -Path $Destination -Force | Out-Null
Copy-Item -Path (Join-Path $source '*') -Destination $Destination -Recurse -Force

Write-Host "Deployed the custom Cooldown Manager to: $Destination"
Write-Host 'Reload World of Warcraft with /reload if the game is running.'
