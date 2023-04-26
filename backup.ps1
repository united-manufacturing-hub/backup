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
    [string]$GpgSigningKeyId = ""
)

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

# Run the backup-grafana.ps1 script with, using $IP and $GrafanaPort as first param and $GrafanaToken as second param
& ./backup-grafana.ps1 -FullUrl "http://${IP}:${GrafanaPort}" -Token ${GrafanaToken} -OutputPath ${OutputPath}
& ./backup-helm.ps1 -KubeconfigPath ${KubeconfigPath} -OutputPath ${OutputPath}
& ./backup-nodered.ps1 -KubeconfigPath ${KubeconfigPath} -OutputPath ${OutputPath}
& ./backup-timescale.ps1 -Ip ${IP} -Password ${DatabasePassword} -Port ${DatabasePort} -User ${DatabaseUser} -Database ${DatabaseDatabase} -OutputPath ${OutputPath} -ParallelJobs ${ParallelJobs} -DaysPerJob ${DaysPerJob}

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
    $OutputObject | ConvertTo-Json -Depth 100 | Set-Content -Path $OutputFile

    # Sign the JSON file using GPG
    gpg --output "$OutputFile.sig" --detach-sig --local-user $GpgSigningKeyId $OutputFile
}

Write-Host "Backup completed in $((Get-Date) - $Now) and saved to ${BackupFolderName}"

