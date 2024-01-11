<#
.SYNOPSIS
    .
.DESCRIPTION
    .
.PARAMETER Path
    The path to the .
.PARAMETER LiteralPath
    Specifies a path to one or more locations. Unlike Path, the value of
    LiteralPath is used exactly as it is typed. No characters are interpreted
    as wildcards. If the path includes escape characters, enclose it in single
    quotation marks. Single quotation marks tell Windows PowerShell not to
    interpret any characters as escape sequences.
.NOTES
    Author: UMH Systems GmbH
#>
param(
    [Parameter(Mandatory=$true)] # IP of the cluster
    [string]$IP = "",

    [Parameter(Mandatory=$false)] # External port of the Grafana service
    [string]$GrafanaPort = "8080",

    [Parameter(Mandatory=$true)] # Grafana API token
    [string]$GrafanaToken = "",

    [Parameter(Mandatory=$false)] # Password of the database user. If default user (factoryinsight) is used, the default password is changeme
    [string]$DatabasePassword = "changeme",

    [Parameter(Mandatory=$false)] # Password of the database user. If default user (factoryinsight) is used, the default password is changeme
    [string]$DatabasePasswordV2 = "changemetoo",

    [Parameter(Mandatory=$false)] # External port of the database
    [int]$DatabasePort = 5432,

    [Parameter(Mandatory=$false)] # Database user
    [string]$DatabaseUser = "factoryinsight",

    [Parameter(Mandatory=$false)] # Database name
    [string]$DatabaseDatabase = "factoryinsight",

    [Parameter(Mandatory=$true)] # Path to the kubeconfig file
    [string]$KubeconfigPath = "",

    [Parameter(Mandatory=$false)] # Skip disk space check
    [bool]$SkipDiskSpaceCheck = $false,

    [Parameter(Mandatory=$false)] # Output path
    [string]$OutputPath = ".",

    [Parameter(Mandatory=$false)] # Parallel jobs
    [int]$ParallelJobs = 4,

    [Parameter(Mandatory=$false)] # Days per job
    [int]$DaysPerJob = 31,

    [Parameter(Mandatory=$false)] # Enable GPG signing
    [bool]$EnableGpgSigning = $false,

    [Parameter(Mandatory=$false)] # GPG signing key ID
    [string]$GpgSigningKeyId = "",

    [Parameter(Mandatory=$false)] # Enable GPG encryption
    [bool]$EnableGpgEncryption = $false,

    [Parameter(Mandatory=$false)] # GPG encryption key ID
    [string]$GpgEncryptionKeyId = "",

    [Parameter(Mandatory=$false)] # Skip GPG questions
    [bool]$SkipGpgQuestions = $false
)

if (Get-Command -ErrorAction Ignore -Type Cmdlet Start-ThreadJob) {
    Write-Host "Module 'ThreadJob' is already installed."
}else{
    Write-Verbose "Installing module 'ThreadJob' on demand..."
    Install-Module -ErrorAction Stop -Scope CurrentUser ThreadJob
}

# Getting here means that Start-ThreadJob is now available.
Get-Command -Type Cmdlet Start-ThreadJob


$Now = Get-Date
Write-Host "Starting backup at $Now"

# Skip if $SkipDiskSpaceCheck is set to true
if ($SkipDiskSpaceCheck) {
    Write-Host "Skipping disk space check"
}else
{

    # Calculate approximate size of the backup
    Write-Host "Calculating approximate size of the backup"
    $env:PGPASSWORD = $DatabasePassword
    $connectionString = "postgres://${DatabaseUser}:${Password}@${IP}:${DatabasePort}/${DatabaseDatabase}?sslmode=require"
    $cmdAnalyze = "ANALYZE;"
    psql -c $cmdAnalyze $connectionString | Out-Null

    $cmd = "SELECT pg_size_pretty(pg_database_size('${DatabaseDatabase}'));"
    psql -c $cmd $connectionString
    $connectionString = ""
    $env:PGPASSWORD = ""
    Write-Host "Do you have enough disk space? (y/n)"
    $answer = Read-Host
    if ($answer -ne "y")
    {
        Write-Host "Aborting backup"
        exit 1
    }
}

# Check if output path exists
if (-not (Test-Path $OutputPath)) {
    Write-Host "Output path (${OutputPath}) does not exist, do you want to create it? (y/n)"
    $answer = Read-Host
    if ($answer -ne "y")
    {
        Write-Host "Aborting backup"
        exit 1
    }
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

if ($EnableGpgEncryption -or $EnableGpgSigning){
    # Check if GPG is in path
    $GpgPath = Get-Command gpg -ErrorAction SilentlyContinue
    if ($GpgPath -eq $null)
    {
        Write-Host "GPG is not in path, please install it and try again"
        exit 1
    }
}

if ($SkipGpgQuestions)
{
    Write-Host "Skipping GPG questions"
}else
{

    # Request GPG signing and encryption keys if they are not set and signing/encryption is enabled
    if ($EnableGpgSigning -and $GpgSigningKeyId -eq "")
    {
        Write-Host "Please enter the GPG signing key ID"
        $GpgSigningKeyId = Read-Host
    }

    if ($EnableGpgEncryption -and $GpgEncryptionKeyId -eq "")
    {
        Write-Host "Please enter the GPG encryption key ID"
        $GpgEncryptionKeyId = Read-Host
    }

    if ($EnableGpgEncryption)
    {
        Write-Host "[WARN] GPG encryption is enabled, if you lose the key, you will not be able to decrypt the backup"
        Write-Host "Do you want to continue? (y/N)"
        $answer = Read-Host
        if ($answer -ne "y")
        {
            Write-Host "Aborting backup"
            exit 1
        }
    }
}

# Run the backup-grafana.ps1 script with, using $IP and $GrafanaPort as first param and $GrafanaToken as second param
& ./backup-grafana.ps1 -FullUrl "http://${IP}:${GrafanaPort}" -Token ${GrafanaToken} -OutputPath ${OutputPath}
& ./backup-helm.ps1 -KubeconfigPath ${KubeconfigPath} -OutputPath ${OutputPath}
& ./backup-nodered.ps1 -KubeconfigPath ${KubeconfigPath} -OutputPath ${OutputPath}
& ./backup-timescale.ps1 -Ip ${IP} -Password ${DatabasePassword} -PasswordV2 ${DatabasePasswordV2} -Port ${DatabasePort} -User ${DatabaseUser} -Database ${DatabaseDatabase} -OutputPath ${OutputPath} -ParallelJobs ${ParallelJobs} -DaysPerJob ${DaysPerJob}
& ./backup-companion.ps1 -IP ${IP} -KubeconfigPath ${KubeconfigPath} -OutputPath ${OutputPath} 

# Create a new folder for the backup
$CurrentDateTimestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$BackupFolderName = "${OutputPath}/backup_${CurrentDateTimestamp}"
New-Item -Path $BackupFolderName -ItemType Directory -Force | Out-Null

# Move the backup files to the backup folder
Move-Item -Path "${OutputPath}/grafana_backup.7z" -Destination "${BackupFolderName}/grafana_backup.7z"
Move-Item -Path "${OutputPath}/helm_backup.7z" -Destination "${BackupFolderName}/helm_backup.7z"
Move-Item -Path "${OutputPath}/nodered_backup.7z" -Destination "${BackupFolderName}/nodered_backup.7z"
Move-Item -Path "${OutputPath}/timescale" -Destination "${BackupFolderName}/timescale"

if ($EnableGpgSigning){
    Write-Host "Signing backup"
    $OutputFile = Join-Path $BackupFolderName "file_hashes.json"
    # Get the current UNIX timestamp
    $UnixTimestamp = [DateTimeOffset]::Now.ToUnixTimeSeconds()

    # Create an empty list to store file hashes and paths
    $FileHashList = @()

    # Iterate through the files in the backup folder and its subfolders
    Get-ChildItem -Path $BackupFolderName -File -Recurse | ForEach-Object {
        $RelativePath = $_.FullName.Substring($BackupFolderName.Length + 1)
        $Hash = (Get-FileHash -Path $_.FullName -Algorithm SHA512).Hash
        $FileHashList += @{
            Path = $RelativePath
            Hash = $Hash
        }
    }

    # Create an object containing the file hash list and the UNIX timestamp
    $OutputObject = @{
        Timestamp = $UnixTimestamp
        Files = $FileHashList
    }

    # Export the object to a JSON file
    $OutputObject | ConvertTo-Json  | Set-Content -Path $OutputFile

    # Sign the JSON file using GPG
    gpg --output "$OutputFile.sig" --detach-sig --local-user $GpgSigningKeyId $OutputFile
    Write-Host "Signed backup"
}

if ($EnableGpgEncryption){
    Write-Host "Encrypting backup"
    # For each file in the backup folder, encrypt it using GPG
    Get-ChildItem -Path $BackupFolderName -File -Recurse | ForEach-Object {
        # Skip file_hashes.json and file_hashes.json.sig
        # There are two information leaks here:
        # 1. The file names are not encrypted
        # 2. The file size is not encrypted
        # Both of them dont really matter.
        if ($_.Name -eq "file_hashes.json" -or $_.Name -eq "file_hashes.json.sig") {
            return
        }

        gpg --output "$($_.FullName).gpg" --encrypt --recipient $GpgEncryptionKeyId $_.FullName
        Remove-Item -Path $_.FullName
    }
    Write-Host "Encrypted backup"
}



Write-Host "Backup completed in $((Get-Date) - $Now) and saved to ${BackupFolderName}"

