@echo off
setlocal EnableExtensions
title Scooby VC++ Runtime Installer

set "SCOOBY_INSTALLER_SELF=%~f0"

rem The runtime installer needs administrator rights.
fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator permission...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $args='/d /c '+$q+$q+$env:SCOOBY_INSTALLER_SELF+$q+$q; Start-Process -FilePath $env:ComSpec -ArgumentList $args -Verb RunAs"
    if errorlevel 1 (
        echo Administrator permission was not granted.
        pause
        exit /b 1
    )
    exit /b 0
)

echo Starting Visual C++ Runtime installer...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$raw=[IO.File]::ReadAllText($env:SCOOBY_INSTALLER_SELF); $marker=([char]35)+' POWERSHELL PAYLOAD'; $at=$raw.IndexOf($marker,[StringComparison]::Ordinal); if($at -lt 0){throw 'PowerShell payload is missing.'}; Invoke-Expression $raw.Substring($at)"
set "SCOOBY_INSTALLER_EXIT=%ERRORLEVEL%"

if not "%SCOOBY_INSTALLER_EXIT%"=="0" (
    echo.
    echo Installation did not complete. Error code: %SCOOBY_INSTALLER_EXIT%
    pause
)

exit /b %SCOOBY_INSTALLER_EXIT%

# POWERSHELL PAYLOAD
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Windows.Forms

$title = 'Scooby VC++ Runtime Installer'
$sourcePage = 'https://www.techpowerup.com/download/visual-c-redistributable-runtime-package-all-in-one/'
$officialPackages = @(
    @{ Architecture = 'x64'; Uri = 'https://aka.ms/vc14/vc_redist.x64.exe' },
    @{ Architecture = 'x86'; Uri = 'https://aka.ms/vc14/vc_redist.x86.exe' }
)
$scriptDirectory = Split-Path -Parent $env:SCOOBY_INSTALLER_SELF
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ScoobyVcRuntimes_' + [Guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $tempRoot 'Visual-C-Runtimes-All-in-One.zip'
$extractPath = Join-Path $tempRoot 'Extracted'
$logRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ScoobyMenu.cc\InstallerLogs'
$logPath = Join-Path $logRoot ('VC-Runtimes-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$restartRequested = $false
$restartRequired = $false
$usedOfflinePackages = $false
$transcriptStarted = $false
$mutex = $null
$ownsMutex = $false
$exitCode = 1

function Show-InstallerError([string]$message) {
    [void][System.Windows.Forms.MessageBox]::Show(
        $message,
        $title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button1,
        [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)
}

function Invoke-WebRequestWithRetry {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Parameters,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$Attempts = 3
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            if ($Parameters.ContainsKey('OutFile') -and (Test-Path -LiteralPath $Parameters.OutFile)) {
                Remove-Item -LiteralPath $Parameters.OutFile -Force -ErrorAction SilentlyContinue
            }
            return Invoke-WebRequest @Parameters
        }
        catch {
            if ($attempt -ge $Attempts) {
                throw ($Description + ' failed after ' + $Attempts + ' attempts. ' + $_.Exception.Message)
            }
            $waitSeconds = [Math]::Min(2 * $attempt, 6)
            Write-Warning ($Description + ' failed (attempt ' + $attempt + '/' + $Attempts + '). Retrying in ' + $waitSeconds + ' seconds...')
            Start-Sleep -Seconds $waitSeconds
        }
    }
}

function Test-MicrosoftSignature([string]$path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    return $signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid -and
        $null -ne $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -match 'Microsoft'
}

function Invoke-CheckedInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$WorkingDirectory = ''
    )

    $startParameters = @{
        FilePath = $FilePath
        ArgumentList = $Arguments
        Wait = $true
        PassThru = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startParameters.WorkingDirectory = $WorkingDirectory
    }

    $process = Start-Process @startParameters
    $successfulCodes = @(0, 1638, 1641, 3010)
    if ($successfulCodes -notcontains $process.ExitCode) {
        throw ($Name + ' returned error code ' + $process.ExitCode + '.')
    }
    if ($process.ExitCode -eq 1641 -or $process.ExitCode -eq 3010) {
        $script:restartRequired = $true
    }
}

function Test-PendingRestart {
    $pendingKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($pendingKey in $pendingKeys) {
        if (Test-Path -LiteralPath $pendingKey) {
            return $true
        }
    }

    try {
        $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction Stop
        if ($null -ne $sessionManager.PendingFileRenameOperations) {
            return $true
        }
    }
    catch { }
    return $false
}

function Install-LocalOfficialRuntimes {
    $localPackages = @(
        @{ Architecture = 'x64'; Path = (Join-Path $scriptDirectory 'vc_redist.x64.exe') },
        @{ Architecture = 'x86'; Path = (Join-Path $scriptDirectory 'vc_redist.x86.exe') }
    )
    $missingLocalPackages = @($localPackages | Where-Object { -not (Test-Path -LiteralPath $_.Path -PathType Leaf) })
    if ($missingLocalPackages.Count -ne 0) {
        return $false
    }

    Write-Host 'Found signed offline Microsoft VC++ packages beside the installer.'
    foreach ($package in $localPackages) {
        $download = Get-Item -LiteralPath $package.Path
        if ($download.Length -lt 1MB -or $download.Length -gt 100MB) {
            throw ('The offline Microsoft ' + $package.Architecture + ' package has an unexpected size.')
        }
        if (-not (Test-MicrosoftSignature -path $package.Path)) {
            throw ('Microsoft signature verification failed for offline vc_redist.' + $package.Architecture + '.exe.')
        }

        $componentLog = Join-Path $logRoot ('VC-Redist-offline-' + $package.Architecture + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        Write-Host ('Installing offline Microsoft VC++ runtime (' + $package.Architecture + ')...')
        Invoke-CheckedInstaller -FilePath $package.Path -Arguments @(
            '/install', '/quiet', '/norestart', '/log', ('"' + $componentLog + '"')
        ) -Name ('Offline Microsoft VC++ runtime (' + $package.Architecture + ')')
    }
    return $true
}

function Test-RequiredX64Runtime {
    if ([Environment]::Is64BitProcess) {
        $nativeSystem = Join-Path $env:SystemRoot 'System32'
    }
    else {
        $nativeSystem = Join-Path $env:SystemRoot 'Sysnative'
    }

    $requiredFiles = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')
    $invalidFiles = @()
    foreach ($requiredFile in $requiredFiles) {
        $runtimePath = Join-Path $nativeSystem $requiredFile
        if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
            $invalidFiles += ($requiredFile + ' (missing)')
        }
        elseif (-not (Test-MicrosoftSignature -path $runtimePath)) {
            $invalidFiles += ($requiredFile + ' (invalid Microsoft signature)')
        }
    }
    if ($invalidFiles.Count -gt 0) {
        throw ('The required x64 runtime verification failed: ' + ($invalidFiles -join ', '))
    }

    $runtimeVersion = (Get-Item -LiteralPath (Join-Path $nativeSystem 'vcruntime140.dll')).VersionInfo.FileVersion
    Write-Host ('Verified x64 VC++ runtime version: ' + $runtimeVersion)
}

function Install-OfficialCurrentRuntimes {
    param([hashtable]$Headers)

    Write-Host 'Using Microsoft-hosted current VC++ runtime packages...'
    foreach ($package in $officialPackages) {
        $architecture = $package.Architecture
        $downloadPath = Join-Path $tempRoot ('vc_redist.' + $architecture + '.exe')
        $componentLog = Join-Path $logRoot ('VC-Redist-' + $architecture + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

        Write-Host ('Downloading Microsoft VC++ runtime (' + $architecture + ')...')
        $request = @{
            Uri = $package.Uri
            Headers = $Headers
            UseBasicParsing = $true
            MaximumRedirection = 10
            OutFile = $downloadPath
        }
        Invoke-WebRequestWithRetry -Parameters $request -Description ('Microsoft ' + $architecture + ' download') | Out-Null

        $download = Get-Item -LiteralPath $downloadPath
        if ($download.Length -lt 1MB -or $download.Length -gt 100MB) {
            throw ('The Microsoft ' + $architecture + ' download has an unexpected size.')
        }
        if (-not (Test-MicrosoftSignature -path $downloadPath)) {
            throw ('Microsoft signature verification failed for vc_redist.' + $architecture + '.exe.')
        }

        Write-Host ('Installing Microsoft VC++ runtime (' + $architecture + ')...')
        Invoke-CheckedInstaller -FilePath $downloadPath -Arguments @(
            '/install', '/quiet', '/norestart', '/log', ('"' + $componentLog + '"')
        ) -Name ('Microsoft VC++ runtime (' + $architecture + ')')
    }
}

function Install-TechPowerUpBundle {
    param(
        [hashtable]$Headers,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session
    )

    Write-Host 'Finding the latest TechPowerUp all-in-one package...'
    $landingRequest = @{
        Uri = $sourcePage
        Headers = $Headers
        UseBasicParsing = $true
        WebSession = $Session
        MaximumRedirection = 10
    }
    $landing = Invoke-WebRequestWithRetry -Parameters $landingRequest -Description 'TechPowerUp package lookup'
    $versionMatch = [regex]::Match(
        $landing.Content,
        '(?is)<form[^>]*class="download-version-form".*?name="id"\s+value="(\d+)"')
    if (-not $versionMatch.Success) {
        throw 'TechPowerUp did not provide a current package ID.'
    }
    $packageId = $versionMatch.Groups[1].Value

    $hashMatch = [regex]::Match($landing.Content, '(?is)SHA(?:-|\s*)256.{0,500}?\b([A-F0-9]{64})\b')
    if (-not $hashMatch.Success) {
        $hashMatch = [regex]::Match($landing.Content, '(?i)\b([A-F0-9]{64})\b')
    }
    if (-not $hashMatch.Success) {
        throw 'TechPowerUp did not provide a SHA-256 checksum.'
    }
    $expectedHash = $hashMatch.Groups[1].Value.ToUpperInvariant()

    $mirrorRequest = @{
        Uri = $sourcePage
        Method = 'Post'
        Body = @{ id = $packageId }
        Headers = $Headers
        ContentType = 'application/x-www-form-urlencoded'
        UseBasicParsing = $true
        WebSession = $Session
        MaximumRedirection = 10
    }
    $mirrorPage = Invoke-WebRequestWithRetry -Parameters $mirrorRequest -Description 'TechPowerUp mirror lookup'
    $serverMatches = [regex]::Matches($mirrorPage.Content, 'name="server_id"\s+value="(\d+)"')
    $serverIds = @($serverMatches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($serverIds.Count -eq 0) {
        throw 'TechPowerUp did not provide an available download mirror.'
    }

    $verifiedDownload = $false
    $mirrorErrors = @()
    foreach ($serverId in $serverIds) {
        try {
            Write-Host ('Downloading from TechPowerUp mirror ' + $serverId + '...')
            $downloadRequest = @{
                Uri = $sourcePage
                Method = 'Post'
                Body = @{ id = $packageId; server_id = $serverId }
                Headers = $Headers
                ContentType = 'application/x-www-form-urlencoded'
                UseBasicParsing = $true
                WebSession = $Session
                MaximumRedirection = 10
                OutFile = $zipPath
            }
            Invoke-WebRequestWithRetry -Parameters $downloadRequest -Description ('TechPowerUp mirror ' + $serverId + ' download') | Out-Null

            $download = Get-Item -LiteralPath $zipPath
            if ($download.Length -lt 10MB -or $download.Length -gt 1GB) {
                throw 'The downloaded archive has an unexpected size.'
            }

            Write-Host 'Verifying the TechPowerUp SHA-256 checksum...'
            $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($actualHash -ne $expectedHash) {
                throw ('SHA-256 mismatch. Expected ' + $expectedHash + ', received ' + $actualHash + '.')
            }
            $verifiedDownload = $true
            break
        }
        catch {
            $mirrorErrors += $_.Exception.Message
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $verifiedDownload) {
        throw ('Every TechPowerUp mirror failed. ' + ($mirrorErrors -join ' | '))
    }

    Write-Host 'Extracting and checking Microsoft signatures...'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    $installer = Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter 'install_all.bat' | Select-Object -First 1
    if ($null -eq $installer) {
        throw 'The verified archive does not contain install_all.bat.'
    }

    $runtimeExecutables = @(Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter '*.exe')
    if ($runtimeExecutables.Count -eq 0) {
        throw 'The archive does not contain any runtime installers.'
    }
    foreach ($runtimeExecutable in $runtimeExecutables) {
        if (-not (Test-MicrosoftSignature -path $runtimeExecutable.FullName)) {
            throw ('Microsoft signature verification failed for: ' + $runtimeExecutable.Name)
        }
    }

    Write-Host ('Installing ' + $runtimeExecutables.Count + ' verified Visual C++ runtime packages...')
    $quotedInstaller = '"' + $installer.FullName + '"'
    Invoke-CheckedInstaller -FilePath $env:ComSpec -Arguments @('/d', '/c', $quotedInstaller) -Name 'TechPowerUp all-in-one runtime installer' -WorkingDirectory $installer.DirectoryName
}

try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\ScoobyVcRuntimeInstaller')
    try {
        $ownsMutex = $mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $ownsMutex = $true
    }
    if (-not $ownsMutex) {
        throw 'Another copy of this installer is already running.'
    }

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'Scooby Loader requires a 64-bit version of Windows.'
    }
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw 'PowerShell 5.0 or newer is required. Install current Windows updates and try again.'
    }

    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    try {
        Start-Transcript -LiteralPath $logPath -Append | Out-Null
        $transcriptStarted = $true
    }
    catch {
        Write-Warning ('Could not start the support log: ' + $_.Exception.Message)
    }

    $tempDrive = New-Object System.IO.DriveInfo([IO.Path]::GetPathRoot($tempRoot))
    if ($tempDrive.AvailableFreeSpace -lt 1500MB) {
        throw 'At least 1.5 GB of free disk space is required for downloading and extracting the runtime package.'
    }

    Write-Host ('Support log: ' + $logPath)
    Write-Host ('Windows: ' + [Environment]::OSVersion.VersionString)
    Write-Host ('PowerShell: ' + $PSVersionTable.PSVersion)
    if (Test-PendingRestart) {
        $restartRequired = $true
        Write-Warning 'Windows already has a pending restart. Installation will continue, but restart afterward.'
    }

    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ScoobyRuntimeInstaller/2.0'
        'Accept' = 'text/html,application/xhtml+xml,application/zip,application/octet-stream,*/*'
    }
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    $allInOneInstalled = $false
    $usedOfflinePackages = Install-LocalOfficialRuntimes
    if ($usedOfflinePackages) {
        Test-RequiredX64Runtime
    }
    else {
        try {
            Install-TechPowerUpBundle -Headers $headers -Session $session
            Test-RequiredX64Runtime
            $allInOneInstalled = $true
        }
        catch {
            Write-Warning ('The all-in-one package could not be completed: ' + $_.Exception.Message)
            Write-Host 'Falling back to the official Microsoft current x64 and x86 packages...'
            Install-OfficialCurrentRuntimes -Headers $headers
            Test-RequiredX64Runtime
        }
    }

    if (Test-PendingRestart) {
        $restartRequired = $true
    }

    if ($allInOneInstalled) {
        $successText = 'All Visual C++ runtimes were installed and verified successfully.'
    }
    elseif ($usedOfflinePackages) {
        $successText = 'The offline Microsoft x64 and x86 Visual C++ runtimes required by Scooby Loader were installed and verified successfully.'
    }
    else {
        $successText = 'The current Microsoft x64 and x86 Visual C++ runtimes required by Scooby Loader were installed and verified successfully.'
    }
    if ($restartRequired) {
        $successText += [Environment]::NewLine + [Environment]::NewLine + 'Windows reported that a restart is required.'
    }
    $successText += [Environment]::NewLine + [Environment]::NewLine + 'Restart your PC now?'

    $choice = [System.Windows.Forms.MessageBox]::Show(
        $successText,
        'Installation complete',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2,
        [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)
    $restartRequested = $choice -eq [System.Windows.Forms.DialogResult]::Yes
    $exitCode = 0
}
catch {
    $message = 'Installation failed.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($logPath)) {
        $message += [Environment]::NewLine + [Environment]::NewLine + 'Support log: ' + $logPath
    }
    Write-Host $message -ForegroundColor Red
    Show-InstallerError $message
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
    if ($ownsMutex -and $null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}

if ($restartRequested) {
    Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList @('/r', '/t', '10', '/c', 'Restart requested after Visual C++ runtime installation.')
}

exit $exitCode
