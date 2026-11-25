# Fetches via scp the artifacts that release/release-mac.sh produced on the Mac and uploads
# them to the GitHub Release, for when the Mac's gh can't publish. The repo: -Repo, else
# $env:RD_RELEASE_REPO, else p-aq/remotedisplay, the same as release-mac.sh.
# Usage:  powershell -ExecutionPolicy Bypass -File release/release-fetch-mac.ps1 [-Tag v0.1.0] [-Repo owner/name]
param([string]$Tag = '', [string]$Repo = '')
if (-not $Repo) { $Repo = $env:RD_RELEASE_REPO }
if (-not $Repo) { $Repo = 'p-aq/remotedisplay' }
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path (Split-Path -Parent $PSCommandPath) '..')
$cfg = Get-Content (Join-Path $root 'remotedisplay\config.local.json') | ConvertFrom-Json
$out = Join-Path $root 'remotedisplay\out'; New-Item -ItemType Directory -Force $out | Out-Null
$version = ((Get-Content (Join-Path $root 'client\pubspec.yaml') | Select-String '^version:') -replace 'version:\s*', '' -split '\+')[0].Trim()
if (-not $Tag) { $Tag = "v$version" }
$remote = "$($cfg.sshUser)@$($cfg.macHost)"
$files = ssh -o BatchMode=yes $remote "ls ~/workspace/remotedisplay/release/out/RemoteDisplay-*$version* 2>/dev/null"
if (-not $files) { throw "No $version artifacts on the Mac (run tools/release-mac.sh there)" }
foreach ($f in $files) { scp -o BatchMode=yes "${remote}:$f" $out; Write-Host "fetched: $(Split-Path $f -Leaf)" }
Push-Location $root
$prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
gh release view $Tag --repo $Repo *> $null; $exists = ($LASTEXITCODE -eq 0); $ErrorActionPreference = $prev
if (-not $exists) { gh release create $Tag --repo $Repo --title "Remote Display $version" --notes "Build $version." | Out-Null }
$local = $files | ForEach-Object { Join-Path $out (Split-Path $_ -Leaf) }
gh release upload $Tag @local --repo $Repo --clobber
Pop-Location
Write-Host "uploaded to GitHub Releases ($Tag)"
