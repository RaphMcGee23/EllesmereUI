param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

if (git -C $repo status --porcelain) {
    throw 'The custom repository has uncommitted changes. Commit or stash them before updating.'
}

git -C $repo fetch upstream --tags
git -C $repo rev-parse --verify "refs/tags/$Version" | Out-Null
git -C $repo switch custom
git -C $repo merge --no-edit $Version

Write-Host "Merged upstream $Version into the custom branch."
Write-Host 'If Git reported conflicts, resolve them before running Deploy-CooldownManager.ps1.'
