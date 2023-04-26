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

    [Parameter(Mandatory=$true)] # Password of the database user. If default user (factoryinsight) is used, the default password is changeme
    [string]$DatabasePassword = "",

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
    [int]$DaysPerJob = 7
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

Write-Host "Backup completed in $((Get-Date) - $Now) and saved to ${BackupFolderName}"

