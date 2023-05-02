param(
    [string]$FullUrl = "",
    [string]$Token = "",
    [string]$OutputPath = "."
)

if (Get-Command -ErrorAction Ignore -Type Cmdlet Start-ThreadJob) {
    Write-Host "Module 'ThreadJob' is already installed."
}else{
    Write-Verbose "Installing module 'ThreadJob' on demand..."
    Install-Module -ErrorAction Stop -Scope CurrentUser ThreadJob
}

# Check if required cmdlets are available
$requiredCmdlets = @("Invoke-RestMethod", "ConvertFrom-Json", "Compress-Archive")
$missingCmdlets = $requiredCmdlets | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) }

if ($missingCmdlets) {
    $psVersion = $PSVersionTable.PSVersion.ToString()
    Write-Host "The following required cmdlets are not available in your PowerShell version ($psVersion):" -ForegroundColor Red
    Write-Host ($missingCmdlets -join ", ") -ForegroundColor Red
    Write-Host "Please use PowerShell Core (version 6 or higher) to run this script." -ForegroundColor Red
    exit 1
}

if (!$FullUrl) {
    $FullUrl = Read-Host -Prompt "Enter the Grafana URL:"
}
if (!$Token) {
    $Token = Read-Host -Prompt "Enter the API token:"
}

$ArchiveName = "${OutputPath}/grafana_backup.7z"

# Check if grafana_backup.7z already exists
if (Test-Path $ArchiveName) {
    $overwrite = Read-Host -Prompt "The file $ArchiveName already exists. Do you want to overwrite it? (y/N)"
    if ($overwrite.ToLower() -ne 'y') {
        Write-Host "Aborted. No changes have been made to the existing $ArchiveName."
        exit 1
    }
}


$Headers = @{
    Authorization = "Bearer $Token"
}
$InPath = "${OutputPath}/grafana/dashboards_raw"

Write-Host "Exporting Grafana dashboards from $FullUrl"
New-Item -Path $InPath -ItemType Directory -Force | Out-Null

$DashListRaw = Invoke-RestMethod -Uri "$FullUrl/api/search?query=&" -Headers $Headers -Method Get

$DashList =  $DashListRaw | Where-Object { $_.type -eq "dash-db" } | Select-Object -ExpandProperty uid

$TotalDashboards = $DashList.Count
Write-Host "Total dashboards found: $TotalDashboards"

$DashboardCounter = 1

foreach ($Dash in $DashList) {
    Write-Host "Processing dashboard $($DashboardCounter)/$($TotalDashboards) - UID: $Dash"
    Invoke-RestMethod -Uri "$FullUrl/api/search?query=&" -Headers $Headers -Method Get | Out-Null
    $DashPath = "$InPath/$Dash.json"
    Invoke-RestMethod -Uri "$FullUrl/api/dashboards/uid/$Dash" -Headers $Headers -Method Get | ConvertTo-Json  | Set-Content $DashPath
    (Get-Content $DashPath | ConvertFrom-Json).dashboard | ConvertTo-Json  | Set-Content "$InPath/dashboard.json"
    $Title = (Get-Content $DashPath | ConvertFrom-Json).dashboard.title
    $Folder = "${OutputPath}/grafana/" + (Get-Content $DashPath | ConvertFrom-Json).meta.folderTitle
    New-Item -Path $Folder -ItemType Directory -Force | Out-Null
    Move-Item -Path "$InPath/dashboard.json" -Destination "$Folder/${Title}.json" -Force
    Write-Host "exported $Folder/${Title}.json"
    $DashboardCounter++
}

Remove-Item -Path $InPath -Recurse -Force

# Compress the grafana folder
$SevenZipPath = ".\_tools\7z.exe"
& $SevenZipPath a -m0=zstd -mx0 -md=16m -mmt=on -mfb=64 "${ArchiveName}" "${OutputPath}/grafana/" | Out-Null

# Delete the grafana folder
Remove-Item -Path "${OutputPath}/grafana" -Recurse -Force

Write-Host "Grafana folder compressed to $ArchiveName and deleted"
