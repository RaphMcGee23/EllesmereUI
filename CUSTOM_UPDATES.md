# Custom EllesmereUI update workflow

This repository uses:

- `upstream` for the official `EllesmereGaming/EllesmereUI` repository.
- `custom` for the local tracking-bar decimal and Arcane timing changes.

## Update to a new official release

Open PowerShell in this directory and run:

```powershell
.\Update-Custom.ps1 -Version v9.1.7
```

Replace `v9.1.7` with the new official release tag. Git will merge the official
release into `custom` while retaining the custom commit. If a conflict occurs,
do not deploy until it has been resolved and committed.

## Deploy to World of Warcraft

```powershell
.\Deploy-CooldownManager.ps1
```

The deploy script copies only `EllesmereUICooldownManager` into the live AddOns
folder. Keep automatic updates disabled for that addon so an addon manager does
not replace the custom build afterward.

## Publish to a GitHub fork

After creating a GitHub fork, add it as `origin` and push the branch:

```powershell
git remote add origin https://github.com/YOUR-NAME/EllesmereUI.git
git push -u origin custom
```

The `upstream` remote should always continue pointing to the official project.
