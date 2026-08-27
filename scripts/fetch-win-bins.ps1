# Fetches the pinned Windows sing-box and OpenVPN binaries, plus the ovpn-dco driver
# package, and places them under WayforkWindows/ (git-ignored; packaged by the build).
#
# Usage: scripts\fetch-win-bins.ps1 [-Arch amd64] [-Clean] [-BuildDir <path>] [-ForceCabinet]
#
#   -Arch amd64                 target architecture (default: amd64)
#   -BuildDir <path>            scratch directory (default: build\win-bins)
#   WAYFORK_BUILD_DIR=<path>    overrides the default scratch directory
#   -Clean                      wipe the scratch directory first
#   -ForceCabinet               take the driver package from the MSI's embedded cabinet
#                               even when the administrative image has it (tests the
#                               fallback used when msiexec /a leaves the drivers out)
#
# Requirements: Windows PowerShell 5.1 or PowerShell 7, internet access, and the stock
# Windows tools msiexec.exe, expand.exe, and the WindowsInstaller.Installer COM object.

[CmdletBinding()]
param(
    [string]$Arch = 'amd64',
    [switch]$Clean,
    [string]$BuildDir,
    [switch]$ForceCabinet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Log {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "==> $Message"
}

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)

    throw $Message
}

function Read-VersionsEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    $lineNumber = 0

    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) {
            continue
        }
        if (-not ($trimmed -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$')) {
            Fail "invalid line $lineNumber in $Path"
        }

        $key = $matches[1]
        $value = $matches[2].Trim()
        if ($value.Length -ge 2) {
            $first = $value.Substring(0, 1)
            $last = $value.Substring($value.Length - 1, 1)
            if (($first -eq '"' -and $last -eq '"') -or
                ($first -eq "'" -and $last -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        $values[$key] = $value
    }

    return $values
}

function Get-RequiredValue {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Values,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if (-not $Values.ContainsKey($Key) -or
        [string]::IsNullOrWhiteSpace([string]$Values[$Key])) {
        Fail "missing required key $Key in scripts/versions.env"
    }
    return [string]($Values[$Key])
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Sha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "missing file: $Path"
    }

    $actual = Get-Sha256 $Path
    if ($actual -ine $Expected) {
        Fail "checksum mismatch for $Path (expected $Expected, got $actual)"
    }
}

function Get-Download {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$Url
    )

    $path = Join-Path $script:DownloadsDir $File
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        if ((Get-Sha256 $path) -ieq $Sha256) {
            return $path
        }
        Log "Cached checksum is invalid for $File; downloading it again"
    }

    $temporaryPath = "$path.tmp"
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    Log "Downloading $File"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $temporaryPath
        Assert-Sha256 $temporaryPath $Sha256
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $temporaryPath -Destination $path
    } catch {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        throw
    }

    return $path
}

function Expand-MsiAdminImage {
    param(
        [Parameter(Mandatory = $true)][string]$MsiPath,
        [Parameter(Mandatory = $true)][string]$TargetDir,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    Remove-Item -LiteralPath $TargetDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Path $TargetDir -Force)

    Log "Extracting OpenVPN MSI administrative image"
    $arguments = @(
        '/a',
        ('"{0}"' -f $MsiPath),
        '/qn',
        ('TARGETDIR="{0}"' -f $TargetDir),
        '/L*v',
        ('"{0}"' -f $LogPath)
    )
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Fail "msiexec administrative extraction failed with exit code $($process.ExitCode); log: $LogPath"
    }
}

function Invoke-Com {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Method,
        [object[]]$Arguments = @()
    )

    return $Object.GetType().InvokeMember(
        $Method,
        [Reflection.BindingFlags]::InvokeMethod,
        $null,
        $Object,
        $Arguments
    )
}

function Get-ComProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Property,
        [object[]]$Arguments = @()
    )

    return $Object.GetType().InvokeMember(
        $Property,
        [Reflection.BindingFlags]::GetProperty,
        $null,
        $Object,
        $Arguments
    )
}

function Release-ComObject {
    param([object]$Object)

    if ($null -ne $Object -and [Runtime.InteropServices.Marshal]::IsComObject($Object)) {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Object)
    }
}

function Export-MsiCabinet {
    param(
        [Parameter(Mandatory = $true)][string]$MsiPath,
        [Parameter(Mandatory = $true)][string]$DestinationDir
    )

    Remove-Item -LiteralPath $DestinationDir -Recurse -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Path $DestinationDir -Force)
    $cabPath = Join-Path $DestinationDir 'openvpn.cab'
    $expandedDir = Join-Path $DestinationDir 'expanded'
    [void](New-Item -ItemType Directory -Path $expandedDir -Force)

    $installer = $null
    $database = $null
    $streamView = $null
    $streamRecord = $null
    $fileView = $null
    $fileRecord = $null
    $members = @{}

    try {
        Log "Exporting openvpn.cab from the MSI"
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = Invoke-Com $installer 'OpenDatabase' @($MsiPath, 0)
        $streamView = Invoke-Com $database 'OpenView' @(
            "SELECT Name, Data FROM _Streams WHERE Name = 'openvpn.cab'"
        )
        [void](Invoke-Com $streamView 'Execute' @())
        $streamRecord = Invoke-Com $streamView 'Fetch' @()
        if ($null -eq $streamRecord) {
            Fail 'openvpn.cab was not found in the OpenVPN MSI'
        }

        $size = [int](Get-ComProperty $streamRecord 'DataSize' @(2))
        if ($size -le 0) {
            Fail 'openvpn.cab in the OpenVPN MSI is empty'
        }
        $data = [string](Invoke-Com $streamRecord 'ReadStream' @(2, $size, 1))
        if ($data.Length -ne $size) {
            Fail "openvpn.cab stream size mismatch (expected $size bytes, got $($data.Length))"
        }

        $bytes = New-Object byte[] $size
        for ($index = 0; $index -lt $size; $index++) {
            $bytes[$index] = [byte]([int][char]$data[$index])
        }
        [IO.File]::WriteAllBytes($cabPath, $bytes)
        $data = $null
        $bytes = $null

        Release-ComObject $streamRecord
        $streamRecord = $null
        [void](Invoke-Com $streamView 'Close' @())
        Release-ComObject $streamView
        $streamView = $null

        $fileView = Invoke-Com $database 'OpenView' @(
            'SELECT File, FileName, Component_ FROM File'
        )
        [void](Invoke-Com $fileView 'Execute' @())
        while ($true) {
            $fileRecord = Invoke-Com $fileView 'Fetch' @()
            if ($null -eq $fileRecord) {
                break
            }
            try {
                $fileKey = [string](Get-ComProperty $fileRecord 'StringData' @(1))
                $rawName = [string](Get-ComProperty $fileRecord 'StringData' @(2))
                $component = [string](Get-ComProperty $fileRecord 'StringData' @(3))
                $nameParts = $rawName -split '\|', 2
                if ($nameParts.Count -eq 2) {
                    $realName = $nameParts[1]
                } else {
                    $realName = $nameParts[0]
                }
                $realName = $realName.ToLowerInvariant()
                if ($component -like '*nx21*' -and
                    $realName -in @('ovpn-dco.inf', 'ovpn-dco.sys', 'ovpn-dco.cat')) {
                    $members[$realName] = Join-Path $expandedDir $fileKey
                }
            } finally {
                Release-ComObject $fileRecord
                $fileRecord = $null
            }
        }
        [void](Invoke-Com $fileView 'Close' @())
        Release-ComObject $fileView
        $fileView = $null

        Log "Expanding openvpn.cab"
        $expandArguments = @(
            ('"{0}"' -f $cabPath),
            '-F:*',
            ('"{0}"' -f $expandedDir)
        )
        $process = Start-Process -FilePath 'expand.exe' -ArgumentList $expandArguments -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            Fail "expand.exe failed with exit code $($process.ExitCode)"
        }

        foreach ($name in @('ovpn-dco.inf', 'ovpn-dco.sys', 'ovpn-dco.cat')) {
            if (-not $members.ContainsKey($name)) {
                Fail "could not map $name to the Win11 nx21 cabinet member"
            }
            if (-not (Test-Path -LiteralPath $members[$name] -PathType Leaf)) {
                Fail "cabinet member for $name was not extracted: $($members[$name])"
            }
        }

        return $members
    } finally {
        Release-ComObject $fileRecord
        Release-ComObject $fileView
        Release-ComObject $streamRecord
        Release-ComObject $streamView
        Release-ComObject $database
        Release-ComObject $installer
    }
}

function Get-DriverPackage {
    param(
        [Parameter(Mandatory = $true)][string]$MsiPath,
        [Parameter(Mandatory = $true)][string]$AdminImageDir,
        [Parameter(Mandatory = $true)][string]$CabinetDir,
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $true)][string]$ArchKey,
        [Parameter(Mandatory = $true)][hashtable]$Versions
    )

    $names = @('ovpn-dco.inf', 'ovpn-dco.sys', 'ovpn-dco.cat')
    $adminDriverDir = Join-Path $AdminImageDir 'OpenVPN\Common Files\ovpn-dco\Win11'
    $sources = @{}
    $adminImageComplete = -not $ForceCabinet
    foreach ($name in $names) {
        if (-not $adminImageComplete) {
            break
        }
        $candidate = Join-Path $adminDriverDir $name
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $adminImageComplete = $false
            break
        }
        $sources[$name] = $candidate
    }

    if ($adminImageComplete) {
        Log "Using ovpn-dco from the MSI administrative image"
    } else {
        Log "Using ovpn-dco from the MSI's embedded cabinet"
        $sources = Export-MsiCabinet $MsiPath $CabinetDir
    }

    [void](New-Item -ItemType Directory -Path $OutputDir -Force)
    foreach ($name in $names) {
        $extension = ([IO.Path]::GetExtension($name)).TrimStart('.').ToUpperInvariant()
        $hashKey = "OVPN_DCO_WIN11_${ArchKey}_SHA256_$extension"
        $expected = Get-RequiredValue $Versions $hashKey
        Assert-Sha256 $sources[$name] $expected
        $destination = Join-Path $OutputDir $name
        Copy-Item -LiteralPath $sources[$name] -Destination $destination -Force
        Assert-Sha256 $destination $expected
    }
}

try {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $versionsPath = Join-Path $root 'scripts\versions.env'
    $versions = Read-VersionsEnv $versionsPath

    $Arch = $Arch.Trim().ToLowerInvariant()
    $archKey = $Arch.ToUpperInvariant()
    $architectureHashKey = "SING_BOX_SHA256_WINDOWS_$archKey"
    if (-not $versions.ContainsKey($architectureHashKey)) {
        Fail "no hashes pinned for $Arch in scripts/versions.env"
    }

    if ([string]::IsNullOrWhiteSpace($BuildDir)) {
        if (-not [string]::IsNullOrWhiteSpace($env:WAYFORK_BUILD_DIR)) {
            $BuildDir = $env:WAYFORK_BUILD_DIR
        } else {
            $BuildDir = Join-Path $root 'build\win-bins'
        }
    }
    $BuildDir = [IO.Path]::GetFullPath($BuildDir)
    $script:DownloadsDir = Join-Path $BuildDir 'downloads'

    if ($Clean -and (Test-Path -LiteralPath $BuildDir)) {
        $volumeRoot = [IO.Path]::GetPathRoot($BuildDir)
        if ($BuildDir.TrimEnd('\') -ieq $volumeRoot.TrimEnd('\') -or
            $BuildDir.TrimEnd('\') -ieq $root.TrimEnd('\')) {
            Fail "refusing to clean unsafe build directory: $BuildDir"
        }
        Log "Cleaning $BuildDir"
        Remove-Item -LiteralPath $BuildDir -Recurse -Force
    }

    [void](New-Item -ItemType Directory -Path $script:DownloadsDir -Force)
    $binOutputDir = Join-Path $root "WayforkWindows\bin\$Arch"
    $driverOutputDir = Join-Path $root "WayforkWindows\drivers\$Arch\ovpn-dco"
    [void](New-Item -ItemType Directory -Path $binOutputDir -Force)
    [void](New-Item -ItemType Directory -Path $driverOutputDir -Force)
    $outputFiles = @()

    $singBoxVersion = Get-RequiredValue $versions 'SING_BOX_VERSION'
    $singBoxArchiveHash = Get-RequiredValue $versions $architectureHashKey
    $singBoxExeHash = Get-RequiredValue $versions "SING_BOX_WIN_${archKey}_SHA256_SING_BOX_EXE"
    $singBoxArchiveName = "sing-box-$singBoxVersion-windows-$Arch.zip"
    $singBoxUrl = "https://github.com/SagerNet/sing-box/releases/download/v$singBoxVersion/$singBoxArchiveName"
    $singBoxArchive = Get-Download $singBoxArchiveName $singBoxArchiveHash $singBoxUrl
    $singBoxExtractDir = Join-Path $BuildDir "sing-box-$Arch"
    Remove-Item -LiteralPath $singBoxExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $singBoxArchive -DestinationPath $singBoxExtractDir -Force
    $singBoxSource = Join-Path $singBoxExtractDir "$($singBoxArchiveName.Substring(0, $singBoxArchiveName.Length - 4))\sing-box.exe"
    Assert-Sha256 $singBoxSource $singBoxExeHash
    $singBoxOutput = Join-Path $binOutputDir 'sing-box.exe'
    Copy-Item -LiteralPath $singBoxSource -Destination $singBoxOutput -Force
    Assert-Sha256 $singBoxOutput $singBoxExeHash
    $outputFiles += $singBoxOutput
    Log "sing-box $singBoxVersion -> $singBoxOutput"

    $openVpnVersion = Get-RequiredValue $versions 'OPENVPN_VERSION'
    $openVpnMsiBuild = Get-RequiredValue $versions 'OPENVPN_MSI_BUILD'
    $openVpnMsiHash = Get-RequiredValue $versions "OPENVPN_MSI_SHA256_$archKey"
    $openVpnMsiName = "OpenVPN-$openVpnVersion-$openVpnMsiBuild-$Arch.msi"
    $openVpnMsiUrl = "https://swupdate.openvpn.org/community/releases/$openVpnMsiName"
    $openVpnMsi = Get-Download $openVpnMsiName $openVpnMsiHash $openVpnMsiUrl
    $adminImageDir = Join-Path $BuildDir "openvpn-msi-$Arch"
    $msiLogPath = Join-Path $BuildDir "openvpn-msi-$Arch.log"
    Expand-MsiAdminImage $openVpnMsi $adminImageDir $msiLogPath

    $openVpnHashPrefix = "OPENVPN_WIN_${archKey}_SHA256_"
    $openVpnEntries = @()
    foreach ($key in $versions.Keys) {
        if (-not ([string]$key).StartsWith($openVpnHashPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $suffix = ([string]$key).Substring($openVpnHashPrefix.Length)
        $lastUnderscore = $suffix.LastIndexOf('_')
        if ($lastUnderscore -le 0 -or $lastUnderscore -eq $suffix.Length - 1) {
            Fail "invalid OpenVPN output hash key: $key"
        }
        $baseName = $suffix.Substring(0, $lastUnderscore).Replace('_', '-').ToLowerInvariant()
        $extension = $suffix.Substring($lastUnderscore + 1).ToLowerInvariant()
        $openVpnEntries += [pscustomobject]@{
            FileName = "$baseName.$extension"
            Hash = [string]($versions[$key])
        }
    }
    if ($openVpnEntries.Count -eq 0) {
        Fail "no hashes pinned for $Arch in scripts/versions.env"
    }

    $openVpnSourceDir = Join-Path $adminImageDir 'OpenVPN\bin'
    foreach ($entry in ($openVpnEntries | Sort-Object FileName)) {
        $source = Join-Path $openVpnSourceDir $entry.FileName
        Assert-Sha256 $source $entry.Hash
        $destination = Join-Path $binOutputDir $entry.FileName
        Copy-Item -LiteralPath $source -Destination $destination -Force
        Assert-Sha256 $destination $entry.Hash
        $outputFiles += $destination
    }
    Log "OpenVPN $openVpnVersion -> $binOutputDir"

    $cabinetDir = Join-Path $BuildDir "openvpn-cab-$Arch"
    Get-DriverPackage $openVpnMsi $adminImageDir $cabinetDir $driverOutputDir $archKey $versions
    foreach ($name in @('ovpn-dco.inf', 'ovpn-dco.sys', 'ovpn-dco.cat')) {
        $outputFiles += Join-Path $driverOutputDir $name
    }
    Log "ovpn-dco -> $driverOutputDir"

    Log 'Result'
    $summary = foreach ($path in $outputFiles) {
        $relativePath = $path.Substring($root.Length)
        if ($relativePath.StartsWith(([IO.Path]::DirectorySeparatorChar).ToString())) {
            $relativePath = $relativePath.Substring(1)
        }
        [pscustomobject]@{
            File = $relativePath
            Size = (Get-Item -LiteralPath $path).Length
            SHA256 = (Get-Sha256 $path).Substring(0, 12)
        }
    }
    $summary | Format-Table -AutoSize | Out-Host
    Write-Host 'Done.'
} catch {
    [Console]::Error.WriteLine("error: $($_.Exception.Message)")
    exit 1
}
