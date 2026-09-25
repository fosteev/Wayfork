# Fetches the pinned block list (scripts/versions.env, BLOCKLIST_*), converts it to
# sing-box's source rule-set format and compiles it with the fetched sing-box.exe into
# windows\rulesets\block-ads.srs next to a block-ads.json sidecar (F18; the Windows
# twin of scripts/fetch-blocklist.sh). Both files are git-ignored and staged into the MSI
# payload by scripts/release-windows.ps1.
#
# Usage: scripts\fetch-win-blocklist.ps1 -Arch amd64|arm64
#
#   -Arch   which fetched sing-box.exe compiles the list (windows\bin\<arch>);
#           the .srs itself is architecture-independent.
#
# Requirements: scripts\fetch-win-bins.ps1 has run for that architecture, curl.exe.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('amd64', 'arm64')][string]$Arch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Log { param([string]$Message) Write-Host "==> $Message" }
function Fail { param([string]$Message) Write-Error "error: $Message"; exit 1 }

function Read-VersionsEnv {
    param([string]$Path)
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        if (-not ($trimmed -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$')) { Fail "invalid line in ${Path}: $trimmed" }
        $key = $matches[1]
        $value = $matches[2].Trim()
        if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        # The URL and licence pins reference ${BLOCKLIST_COMMIT}; expand it like the shell does.
        foreach ($known in @($values.Keys)) {
            $value = $value.Replace('${' + $known + '}', [string]$values[$known])
        }
        $values[$key] = $value
    }
    return $values
}

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$pins = Read-VersionsEnv (Join-Path $root 'scripts\versions.env')
foreach ($key in @('BLOCKLIST_NAME', 'BLOCKLIST_HOMEPAGE', 'BLOCKLIST_COMMIT', 'BLOCKLIST_URL', 'BLOCKLIST_SHA256', 'BLOCKLIST_LICENSE')) {
    if (-not $pins.ContainsKey($key)) { Fail "missing $key in scripts/versions.env" }
}

# The .srs is architecture-independent, so the compiler is whichever fetched sing-box.exe
# runs on this host: the amd64 one when it is there (it runs on an x64 machine and, through
# emulation, on ARM64 Windows), else the one of -Arch. An arm64 sing-box.exe on an x64 runner
# does not run at all.
$candidates = @(
    (Join-Path $root 'windows\bin\amd64\sing-box.exe'),
    (Join-Path $root "windows\bin\$Arch\sing-box.exe")
)
$singBox = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $singBox) {
    Fail "no fetched sing-box.exe under windows\bin; run scripts\fetch-win-bins.ps1 -Arch $Arch first"
}
$outDir = Join-Path $root 'windows\rulesets'
$buildDir = Join-Path $root 'build\blocklist'
[void](New-Item -ItemType Directory -Path $outDir, $buildDir -Force)

$raw = Join-Path $buildDir ("blocklist-" + $pins['BLOCKLIST_COMMIT'] + ".txt")
if (-not (Test-Path -LiteralPath $raw -PathType Leaf)) {
    Log ("Downloading " + $pins['BLOCKLIST_NAME'] + " (" + $pins['BLOCKLIST_COMMIT'] + ")")
    & curl.exe -fsSL --retry 3 -o "$raw.part" $pins['BLOCKLIST_URL']
    if ($LASTEXITCODE -ne 0) { Fail "download failed" }
    Move-Item -LiteralPath "$raw.part" -Destination $raw -Force
}
$actual = (Get-FileHash -LiteralPath $raw -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ine $pins['BLOCKLIST_SHA256']) {
    Fail ("checksum mismatch for the block list: expected " + $pins['BLOCKLIST_SHA256'] + ", got $actual")
}

Log 'Converting to a sing-box rule-set'
$version = ''
$entries = New-Object System.Collections.Generic.List[string]
foreach ($line in [IO.File]::ReadAllLines($raw)) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0) { continue }
    if ($trimmed.StartsWith('#')) {
        if ($version -eq '' -and $trimmed -match '^# Version:\s*(\S+)') { $version = $matches[1] }
        continue
    }
    # Entries: lowercase hostnames only; anything else is a format change worth a look.
    if (-not ($trimmed -match '^[a-z0-9.-]+$')) { Fail "unexpected entry in the block list: $trimmed" }
    $entries.Add($trimmed)
}
$source = Join-Path $buildDir 'block-ads.source.json'
$quoted = New-Object System.Collections.Generic.List[string]
foreach ($entry in $entries) { $quoted.Add('"' + $entry + '"') }
$json = '{"version":3,"rules":[{"domain_suffix":[' + ($quoted -join ',') + ']}]}'
[IO.File]::WriteAllText($source, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))

Log ("Compiling " + $entries.Count + " entries")
$compiled = Join-Path $outDir 'block-ads.srs'
& $singBox rule-set compile --output $compiled $source
if ($LASTEXITCODE -ne 0) { Fail 'sing-box rule-set compile failed' }
$sidecar = @{
    name     = $pins['BLOCKLIST_NAME']
    homepage = $pins['BLOCKLIST_HOMEPAGE']
    license  = $pins['BLOCKLIST_LICENSE']
    commit   = $pins['BLOCKLIST_COMMIT']
    version  = $version
    entries  = $entries.Count
}
[IO.File]::WriteAllText((Join-Path $outDir 'block-ads.json'), (($sidecar | ConvertTo-Json) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
Log ("Wrote $compiled and block-ads.json")
