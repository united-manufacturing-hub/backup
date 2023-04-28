param(
    [string]$FullUrl = "",
    [string]$Token = "",
    [string]$BackupPath = ""
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

# Check if the backup folder exists and contains helm_backup.7z
if (!(Test-Path $BackupPath)) {
    Write-Host "The backup folder $BackupPath does not exist."
    exit 1
}

$IsEncrypted = $false
# Check if grafana_backup.7z.gpg exists and if so, decrypt it
if (Test-Path "$BackupPath\grafana_backup.7z.gpg") {
    $IsEncrypted = $true
    Write-Host "Decrypting grafana_backup.7z.gpg..."
    gpg --decrypt --output "$BackupPath\grafana_backup.7z" "$BackupPath\grafana_backup.7z.gpg"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "GPG decryption failed. Aborting the process."
        exit 1
    }
}

if (!(Test-Path "$BackupPath\grafana_backup.7z")) {
    Write-Host "The backup folder $BackupPath does not contain a grafana_backup.7z file."
    exit 1
}

# Verify GPG signature
$SignedFile = Join-Path $BackupFolderName "file_hashes.json"
$SignatureFile = Join-Path $BackupFolderName "file_hashes.json.sig"

$CheckGPG = $true
if (!(Test-Path $SignedFile) -or !(Test-Path $SignatureFile)) {
    Write-Host "The signed file or its signature is missing in the backup folder."
    $CheckGPG = $false

    Write-Host "Do you want to continue without GPG signature verification? (y/n)"
    $answer = Read-Host
    if ($answer -ne "y") {
        exit 1
    }
}

if ($CheckGPG)
{
    gpg --verify $SignatureFile $SignedFile
    if ($LASTEXITCODE -ne 0)
    {
        Write-Host "GPG signature verification failed. Aborting the process."
        exit 1
    }

    # Load the JSON file with the file hashes
    $FileHashes = (Get-Content -Path $SignedFile | ConvertFrom-Json).Files

    function Verify-FileHash($FilePath, $ExpectedHash)
    {
        $ActualHash = (Get-FileHash -Path $FilePath -Algorithm SHA512).Hash
        return $ActualHash -eq $ExpectedHash
    }

    # Verify the hash of the grafana_backup.7z file
    $HelmBackupFile = Join-Path $BackupPath "grafana_backup.7z"
    $HelmBackupHash = ($FileHashes | Where-Object { $_.Path -eq "grafana_backup.7z" }).Hash

    if (!(Verify-FileHash -FilePath $HelmBackupFile -ExpectedHash $HelmBackupHash))
    {
        Write-Host "Hash verification failed for grafana_backup.7z. Aborting the process."
        exit 1
    }
}

$UnpackagedgrafanaPath = ".\grafana"
$SevenZipPath = ".\_tools\7z.exe"
# Decompress the grafana folder
& $SevenZipPath x -y -o"$UnpackagedgrafanaPath" "$BackupPath\grafana_backup.7z" | Out-Null

# Set headers for the API request
$headers = @{
    'Authorization' = "Bearer $Token"
    'Content-Type' = 'application/json'
}

# Make the API request
$apiUrl = "$FullUrl/api/datasources"
$datasourcesJson = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $headers

# Extract the 'type' and 'uid' from the JSON response and create a map
$typeUidMap = @{}
foreach ($datasource in $datasourcesJson) {
    $typeUidMap[$datasource.type] = $datasource.uid
}

# Recursively find all JSON files in the 'grafana' folder
$jsonFiles = Get-ChildItem -Path "$UnpackagedgrafanaPath" -Recurse -Filter "*.json"

# Process each JSON file
foreach ($jsonFile in $jsonFiles) {
    # Read the JSON file and convert it to a PowerShell object
    $jsonContent = Get-Content -Path $jsonFile.FullName -Raw | ConvertFrom-Json -Depth 100

    # Function to process JSON objects recursively
    function Process-JsonObject {
        param (
            [Parameter(ValueFromPipeline)]
            $InputObject
        )

        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            # If the input object is a collection (e.g., array), process each element
            foreach ($item in $InputObject) {
                Process-JsonObject $item
            }
        }
        elseif ($InputObject -is [psobject]) {
            # If the input object is a PSObject, check for "datasource" key and process properties
            $properties = $InputObject | Get-Member -MemberType NoteProperty
            foreach ($property in $properties) {
                $value = $InputObject.$($property.Name)
                if ($property.Name -eq "datasource" -and $value.type -and $value.uid) {
                    # If the "datasource" key is found, update the "uid" using the map
                    $value.uid = $typeUidMap[$value.type]
                }
                # Recursively process the value of the property
                Process-JsonObject $value
            }
        }
    }

    # Process the JSON content and update "uid" values
    Process-JsonObject $jsonContent

    # Save the updated JSON content back to the original file
    $jsonContent | ConvertTo-Json -Depth 100 | Set-Content -Path $jsonFile.FullName
}

# Get the unique folder names from the JSON file paths
$folderNames = $jsonFiles | ForEach-Object { Split-Path -Path $_.DirectoryName -Leaf } | Sort-Object -Unique

# Initialize a new map to store the folder name and the returned uid
$folderUidMap = @{}

# Get the existing folders from the API
$getFoldersApiUrl = "$FullUrl/api/folders?limit=1000"
$existingFolders = Invoke-RestMethod -Uri $getFoldersApiUrl -Method Get -Headers $headers

foreach ($folderName in $folderNames) {
    # Skip the folder named "General"
    if ($folderName -eq "General") {
        continue
    }

    # Check if the folder already exists
    $existingFolder = $existingFolders | Where-Object { $_.title -eq $folderName }

    if ($existingFolder) {
        # Update the folderUidMap with the existing folder's uid
        $folderUidMap[$folderName] = $existingFolder.uid
    } else {
        # Create the folder using the API request
        $folderCreationApiUrl = "$FullUrl/api/folders"
        $folderCreationBody = @{
            "title" = $folderName
        } | ConvertTo-Json -Depth 100

        $folderCreationResponse = Invoke-RestMethod -Uri $folderCreationApiUrl -Method Post -Headers $headers -Body $folderCreationBody

        # Add the folder name and the returned uid to the map
        $folderUidMap[$folderName] = $folderCreationResponse.uid
    }
}

foreach ($jsonFile in $jsonFiles) {
    # Get the folder name for the current JSON file
    $folderName = Split-Path -Path $jsonFile.DirectoryName -Leaf

    # Get the folder UID from the folderUidMap, if the folder name exists in the map
    $folderUid = $null
    if ($folderUidMap.ContainsKey($folderName)) {
        $folderUid = $folderUidMap[$folderName]
    }

    # Read the JSON file content
    $jsonFileContent = Get-Content -Path $jsonFile.FullName -Raw | ConvertFrom-Json -Depth 100

    # Set the id field to null
    $jsonFileContent.id = $null

    # Create the request body
    $dashboardPostBody = @{
        "dashboard" = $jsonFileContent
        "message"    = "Imported"
        "overwrite"  = $true
    }

    # Set the folderUid only if it's not null
    if ($folderUid -ne $null) {
        $dashboardPostBody["folderUid"] = $folderUid
    }

    $dashboardPostBody = $dashboardPostBody | ConvertTo-Json -Depth 100

    # Post the JSON file to the /api/dashboards/db endpoint
    $dashboardPostApiUrl = "$FullUrl/api/dashboards/db"
    Invoke-RestMethod -Uri $dashboardPostApiUrl -Method Post -Headers $headers -Body $dashboardPostBody
}

# Delete the unpackaged grafana folder
Remove-Item -Path $UnpackagedgrafanaPath -Recurse -Force

if ($IsEncrypted){
    # Remove the decrypted 7z file
    Remove-Item -Path "${BackupPath}\grafana_backup.7z" -Recurse -Force | Out-Nulls
}
