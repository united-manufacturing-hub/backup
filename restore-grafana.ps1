param(
    [string]$FullUrl = "",
    [string]$Token = "",
    [string]$BackupPath = ""
)

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

if (!(Test-Path "$BackupPath\grafana_backup.7z")) {
    Write-Host "The backup folder $BackupPath does not contain a grafana_backup.7z file."
    exit 1
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
    $jsonContent = Get-Content -Path $jsonFile.FullName -Raw | ConvertFrom-Json

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

foreach ($folderName in $folderNames) {
    # Skip the folder named "General"
    if ($folderName -eq "General") {
        continue
    }

    # Create the folder using the API request
    $folderCreationApiUrl = "$FullUrl/api/folders"
    $folderCreationBody = @{
        "title" = $folderName
    } | ConvertTo-Json

    $folderCreationResponse = Invoke-RestMethod -Uri $folderCreationApiUrl -Method Post -Headers $headers -Body $folderCreationBody

    # Add the folder name and the returned uid to the map
    $folderUidMap[$folderName] = $folderCreationResponse.uid
}

# Output the folderUidMap
$folderUidMap
