# Builds the distributable Wayfork MSIs: the Flutter app, the Go service, the pinned
# binaries and the ovpn-dco package staged into one payload per architecture, then WiX.
#
# Usage: scripts\release-windows.ps1 [-Version X.Y.Z] [-Arch amd64|arm64|both]
#                                    [-SkipFetch] [-SkipFlutter]
#                                    [-CertificatePath <pfx>] [-CertificatePassword <secret>]
#                                    [-TimestampUrl <url>] [-BuildDir <path>]
#
#   -Version X.Y.Z         must equal the app's version — a guard against building a
#                          release of the wrong version. Default: what the app declares.
#   -Arch both             which packages to build (default: both).
#   -SkipFetch             reuse WayforkWindows\bin\<arch> and drivers\<arch> as they are.
#   -SkipFlutter           reuse the last `flutter build windows --release`.
#   -CertificatePath       PFX to sign Wayfork's own binaries, the MSIs and the bundle
#                          (through `wix burn detach`/`reattach`) with. Without it
#                          the artefacts are unsigned: there is no certificate yet, and
#                          SmartScreen will warn on first run (README).
#   -TimestampUrl          RFC 3161 timestamp server (default: DigiCert's).
#
# Output (build\release-windows\):
#   Wayfork-<version>-<arch>.msi (+ .sha256)
#   Wayfork-<version>.exe (+ .sha256)   both MSIs in one bundle, -Arch both only
#
# Requires: Windows, the pinned Flutter and Go toolchains (WayforkWindows\versions.env),
# the .NET SDK for the WiX tool, and network access on the first run (WiX, the pinned
# binaries, the timestamp server).

[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('amd64', 'arm64', 'both')][string]$Arch = 'both',
    [switch]$SkipFetch,
    [switch]$SkipFlutter,
    [string]$CertificatePath,
    [string]$CertificatePassword,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [string]$BuildDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

function Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "==> $Message"
}

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw $Message
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $previous = $null
    if ($WorkingDirectory) {
        $previous = (Get-Location).Path
        Set-Location -LiteralPath $WorkingDirectory
    }
    try {
        # To the host, never down the pipeline: a caller that returns a value must not
        # collect the child's output along with it.
        & $FilePath @Arguments | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Fail "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
        }
    } finally {
        if ($previous) { Set-Location -LiteralPath $previous }
    }
}

function Read-EnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$') { continue }
        $values[$matches[1]] = $matches[2].Trim()
    }
    return $values
}

# The version the app declares; the MSI and the service are stamped with it.
function Get-AppVersion {
    param([Parameter(Mandatory = $true)][string]$Root)

    $dartPath = Join-Path $Root 'WayforkWindows\app\lib\core\version.dart'
    $dart = Get-Content -LiteralPath $dartPath -Raw
    if ($dart -notmatch "app\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'") {
        Fail "cannot read the app version from $dartPath"
    }
    $version = $matches[1]
    $pubspecPath = Join-Path $Root 'WayforkWindows\app\pubspec.yaml'
    $pubspec = Get-Content -LiteralPath $pubspecPath -Raw
    if ($pubspec -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
        Fail "cannot read the version from $pubspecPath"
    }
    if ($matches[1] -ne $version) {
        Fail "pubspec.yaml says $($matches[1]) but version.dart says $version"
    }
    return $version
}

function Get-SignTool {
    $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles) | Where-Object { $_ }
    foreach ($root in $roots) {
        $candidates = Get-ChildItem -Path (Join-Path $root 'Windows Kits\10\bin') -Filter 'signtool.exe' `
            -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName -Descending
        foreach ($candidate in $candidates) {
            if ($candidate.FullName -match '\\(x64|arm64|x86)\\signtool\.exe$') { return $candidate.FullName }
        }
    }
    Fail 'signtool.exe not found; install the Windows SDK or drop -CertificatePath'
}

# Signs Wayfork's own binaries. The bundled sing-box, OpenVPN and driver files keep their
# vendors' signatures and are never re-signed.
function Set-Signature {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    if (-not $CertificatePath) { return }
    $signtool = Get-SignTool
    $arguments = @('sign', '/fd', 'SHA256', '/tr', $TimestampUrl, '/td', 'SHA256', '/f', $CertificatePath)
    if ($CertificatePassword) { $arguments += @('/p', $CertificatePassword) }
    Invoke-Tool $signtool ($arguments + $Paths)
}

function Install-WixTool {
    param([Parameter(Mandatory = $true)][string]$WixVersion)

    $wix = Get-Command wix -ErrorAction SilentlyContinue
    $installed = ''
    if ($wix) { $installed = ((& $wix.Source --version) | Select-Object -First 1) -replace '\s', '' }
    # `wix --version` prints 7.0.0+<commit>; the pin is the part before the metadata.
    if ($installed -eq $WixVersion -or $installed.StartsWith("$WixVersion+")) { return $wix.Source }
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Fail "the .NET SDK is needed for WiX $WixVersion (https://dotnet.microsoft.com/download)"
    }
    $verb = if ($wix) { 'update' } else { 'install' }
    Log "Installing WiX $WixVersion ($verb)"
    Invoke-Tool 'dotnet' @('tool', $verb, '--global', 'wix', '--version', $WixVersion)
    $wix = Get-Command wix -ErrorAction SilentlyContinue
    if (-not $wix) {
        Fail 'wix is not on PATH after the install; open a new shell and try again'
    }
    return $wix.Source
}

# The bundle needs the bootstrapper-application extension, versioned with WiX itself.
function Install-WixExtension {
    param(
        [Parameter(Mandatory = $true)][string]$WixPath,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$WixVersion
    )

    $listed = & $WixPath extension list --global 2>$null
    if ($listed -and ($listed | Where-Object { $_ -match [regex]::Escape("$Name/$WixVersion") })) { return }
    Log "Adding the WiX extension $Name/$WixVersion"
    Invoke-Tool $WixPath @('extension', 'add', '--global', "$Name/$WixVersion")
}

# A Burn bundle cannot be signed in one go: the engine has to come out, be signed, go back
# in, and only then is the bundle itself signed (WiX "Insignia" flow).
function Set-BundleSignature {
    param(
        [Parameter(Mandatory = $true)][string]$WixPath,
        [Parameter(Mandatory = $true)][string]$Bundle
    )

    if (-not $CertificatePath) { return }
    $engine = "$Bundle.engine.exe"
    Invoke-Tool $WixPath @('burn', 'detach', $Bundle, '-engine', $engine)
    Set-Signature @($engine)
    Invoke-Tool $WixPath @('burn', 'reattach', $Bundle, '-engine', $engine, '-out', $Bundle)
    Set-Signature @($Bundle)
    Remove-Item -LiteralPath $engine -Force -ErrorAction SilentlyContinue
}

try {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $appDir = Join-Path $root 'WayforkWindows\app'
    $serviceDir = Join-Path $root 'WayforkWindows\service'
    $versions = Read-EnvFile (Join-Path $root 'WayforkWindows\versions.env')
    if (-not $versions.ContainsKey('WIX_VERSION')) { Fail 'WIX_VERSION is missing from WayforkWindows/versions.env' }
    $wixVersion = $versions['WIX_VERSION']

    $appVersion = Get-AppVersion $root
    if (-not $Version) { $Version = $appVersion }
    if ($Version -ne $appVersion) {
        Fail "-Version $Version does not match the app's $appVersion"
    }

    if (-not $BuildDir) { $BuildDir = Join-Path $root 'build' }
    $BuildDir = [IO.Path]::GetFullPath($BuildDir)
    $outputDir = Join-Path $BuildDir 'release-windows'
    $stageRoot = Join-Path $BuildDir 'stage-windows'
    [void](New-Item -ItemType Directory -Path $outputDir -Force)

    $architectures = if ($Arch -eq 'both') { @('amd64', 'arm64') } else { @($Arch) }
    $wixPath = Install-WixTool $wixVersion

    # One Flutter build for both packages: Flutter publishes no arm64 Windows archive, so
    # the app is x64 everywhere and runs emulated on ARM64 (docs/design/08-windows.md).
    $flutterRelease = Join-Path $appDir 'build\windows\x64\runner\Release'
    if (-not $SkipFlutter) {
        Log 'Building the Flutter app (x64)'
        Invoke-Tool 'flutter' @('build', 'windows', '--release') -WorkingDirectory $appDir
    }
    if (-not (Test-Path -LiteralPath (Join-Path $flutterRelease 'wayfork.exe'))) {
        Fail "no Flutter release build in $flutterRelease"
    }

    $artefacts = @()
    foreach ($architecture in $architectures) {
        Log "Packaging $architecture"
        if (-not $SkipFetch) {
            Invoke-Tool 'powershell' @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', (Join-Path $root 'scripts\fetch-win-bins.ps1'), '-Arch', $architecture)
        }
        $binDir = Join-Path $root "WayforkWindows\bin\$architecture"
        $driverDir = Join-Path $root "WayforkWindows\drivers\$architecture\ovpn-dco"
        foreach ($required in @($binDir, $driverDir)) {
            if (-not (Test-Path -LiteralPath $required)) {
                Fail "missing $required (run scripts\fetch-win-bins.ps1 -Arch $architecture)"
            }
        }

        # The payload is harvested whole by WiX, so the service executable — the one file
        # that needs a component of its own — is staged next to it, not inside it.
        $stage = Join-Path $stageRoot $architecture
        $payload = Join-Path $stage 'payload'
        $serviceStage = Join-Path $stage 'service'
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        [void](New-Item -ItemType Directory -Path $payload, $serviceStage -Force)
        Copy-Item -Path (Join-Path $flutterRelease '*') -Destination $payload -Recurse -Force
        Copy-Item -LiteralPath $binDir -Destination (Join-Path $payload 'bin') -Recurse -Force
        [void](New-Item -ItemType Directory -Path (Join-Path $payload 'drivers') -Force)
        Copy-Item -LiteralPath $driverDir -Destination (Join-Path $payload 'drivers\ovpn-dco') -Recurse -Force

        Log "Building the service ($architecture)"
        $ldflags = "-s -w -X wayfork/service/internal/service.Version=$Version"
        foreach ($command in @('wayfork-service', 'wayforkctl')) {
            $destination = if ($command -eq 'wayfork-service') { $serviceStage } else { $payload }
            $env:GOOS = 'windows'
            $env:GOARCH = $architecture
            $env:CGO_ENABLED = '0'
            Invoke-Tool 'go' @(
                'build', '-trimpath', '-ldflags', $ldflags,
                '-o', (Join-Path $destination "$command.exe"), "./cmd/$command") -WorkingDirectory $serviceDir
        }
        Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue

        # Ours only: the bundled sing-box, OpenVPN and driver keep their vendors' signatures.
        Set-Signature @(
            (Join-Path $payload 'wayfork.exe'),
            (Join-Path $payload 'wayforkctl.exe'),
            (Join-Path $serviceStage 'wayfork-service.exe'))

        $wixArch = if ($architecture -eq 'amd64') { 'x64' } else { 'arm64' }
        $msi = Join-Path $outputDir "Wayfork-$Version-$architecture.msi"
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        Log "Building $([IO.Path]::GetFileName($msi))"
        Invoke-Tool $wixPath @(
            'build', (Join-Path $root 'WayforkWindows\installer\Wayfork.wxs'),
            '-arch', $wixArch,
            '-d', "Version=$Version",
            '-bindpath', "Payload=$payload",
            '-bindpath', "Service=$serviceStage",
            '-out', $msi)
        Set-Signature @($msi)

        $hash = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($msi))" | Set-Content -LiteralPath "$msi.sha256" -Encoding ascii
        $artefacts += [pscustomobject]@{
            File = [IO.Path]::GetFileName($msi)
            Size = (Get-Item -LiteralPath $msi).Length
            SHA256 = $hash.Substring(0, 12)
        }
    }

    # The bundle is what the release page offers first: one download for both machines. It
    # needs both packages, so a single-architecture build stops at the MSI.
    if ($architectures.Count -eq 2) {
        Install-WixExtension $wixPath 'WixToolset.BootstrapperApplications.wixext' $wixVersion
        $bundle = Join-Path $outputDir "Wayfork-$Version.exe"
        Remove-Item -LiteralPath $bundle -Force -ErrorAction SilentlyContinue
        Log "Building $([IO.Path]::GetFileName($bundle))"
        Invoke-Tool $wixPath @(
            'build', (Join-Path $root 'WayforkWindows\installer\WayforkBundle.wxs'),
            '-arch', 'x86',
            '-ext', 'WixToolset.BootstrapperApplications.wixext',
            '-d', "Version=$Version",
            '-bindpath', "Msi=$outputDir",
            '-bindpath', "Icon=$(Join-Path $appDir 'assets\tray\light')",
            '-out', $bundle)
        Set-BundleSignature $wixPath $bundle

        $hash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($bundle))" | Set-Content -LiteralPath "$bundle.sha256" -Encoding ascii
        $artefacts += [pscustomobject]@{
            File = [IO.Path]::GetFileName($bundle)
            Size = (Get-Item -LiteralPath $bundle).Length
            SHA256 = $hash.Substring(0, 12)
        }
    }

    Log 'Result'
    $artefacts | Format-Table -AutoSize | Out-Host
    if (-not $CertificatePath) {
        Log 'Unsigned build: SmartScreen will warn on first run (README, "Install").'
    }
    Write-Host 'Done.'
} catch {
    [Console]::Error.WriteLine("error: $($_.Exception.Message)")
    exit 1
}
