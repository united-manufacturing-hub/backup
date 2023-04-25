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

    [Parameter(Mandatory=$true)] # External port of the Grafana service
    [string]$GrafanaPort = "",

    [Parameter(Mandatory=$true)] # Grafana API token
    [string]$GrafanaToken = "",

    [Parameter(Mandatory=$true)] # Password of the database user
    [string]$DatabasePassword = "",

    [Parameter(Mandatory=$false)] # External port of the database
    [int]$DatabasePort = 5432,

    [Parameter(Mandatory=$false)] # Database user
    [string]$DatabaseUser = "factoryinsight",

    [Parameter(Mandatory=$false)] # Database name
    [string]$DatabaseDatabase = "factoryinsight",

    [Parameter(Mandatory=$true)] # Path to the kubeconfig file
    [string]$KubeconfigPath = ""
)

$Now = Get-Date
Write-Host "Starting backup at $Now"

# Run the backup-grafana.ps1 script with, using $IP and $GrafanaPort as first param and $GrafanaToken as second param
& ./backup-grafana.ps1 -FullUrl "http://${IP}:${GrafanaPort}" -Token ${GrafanaToken}
& ./backup-helm.ps1 -KubeconfigPath ${KubeconfigPath}
& ./backup-nodered.ps1 -KubeconfigPath ${KubeconfigPath}
& ./backup-timescale.ps1 -Ip ${IP} -Password ${DatabasePassword} -Port ${DatabasePort} -User ${DatabaseUser} -Database ${DatabaseDatabase}

# Create a new folder for the backup
$CurrentDateTimestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$BackupFolderName = "backup_${CurrentDateTimestamp}"
New-Item -Path $BackupFolderName -ItemType Directory -Force | Out-Null

# Move the backup files to the backup folder
Move-Item -Path "./grafana_backup.7z" -Destination "./${BackupFolderName}/grafana_backup.7z"
Move-Item -Path "./helm_backup.7z" -Destination "./${BackupFolderName}/helm_backup.7z"
Move-Item -Path "./nodered_backup.7z" -Destination "./${BackupFolderName}/nodered_backup.7z"
Move-Item -Path "./timescale" -Destination "./${BackupFolderName}/timescale"

Write-Host "Backup completed in $((Get-Date) - $Now) and saved to ${BackupFolderName}"

