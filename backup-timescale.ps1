param(
    [string]$Ip = "",
    [string]$Password = "",
    [int]$Port = 5432,
    [string]$User = "factoryinsight",
    [string]$Database = "factoryinsight"
)

if (!$Ip) {
    $Ip = Read-Host -Prompt "Enter the IP of your cluster:"
}

if (!$Password) {
    $Password = Read-Host -Prompt "Enter the password of your postgresql ($User) user:"
}

$ArchiveName = "./timescale"
if (Test-Path $ArchiveName) {
    $overwrite = Read-Host -Prompt "The folder $ArchiveName already exists. Do you want to overwrite it? (y/N)"
    if ($overwrite.ToLower() -ne 'y') {
        Write-Host "Aborted. No changes have been made to the existing $ArchiveName."
        exit 1
    }
    
    Remove-Item -Path "./timescale" -Recurse -Force
}
New-Item -Path $ArchiveName -ItemType Directory -Force | Out-Null
New-Item -Path "$ArchiveName/tables" -ItemType Directory -Force | Out-Null


# Set env variable for PGPASSWORD
$env:PGPASSWORD = $Password

# Dump pre-data
pg_dump -U $User -h $Ip -p $Port -Fc -v --section=pre-data --exclude-schema="_timescaledb*" -f ./timescale/dump_pre_data.bak $Database

# Connect to the source database
$connectionString = "postgres://${User}:${Password}@${Ip}:${Port}/${Database}?sslmode=require"

# Predefined table names
$TableNames = @(
    "assetTable",
    "stateTable",
    "countTable",
    "uniqueProductTable",
    "recommendationTable",
    "shiftTable",
    "productTable",
    "orderTable",
    "configurationTable",
    "productTagTable",
    "productTagStringTable",
    "productInheritanceTable",
    "componenttable",
    "maintenanceactivities",
    "timebasedmaintenance"
)


$SevenZipPath = ".\_tools\7z.exe"

foreach ($tableName in $TableNames) {
    Write-Host "Backing up $tableName"
    $csvPath = "./timescale/tables/${tableName}.csv"
    $zipPath = "./timescale/tables/${tableName}.7z"
    $copyCommand = "\COPY (SELECT * FROM ${tableName}) TO '${csvPath}' CSV"
    psql -c $copyCommand $connectionString

    # Create a zip archive for the CSV file
    Compress-Archive -Path $csvPath -DestinationPath $zipPath -Force
    & $SevenZipPath a -m0=zstd -mx0 -md=16m -mmt=on -mfb=64 "${csvPath}.7z" $csvPath

    # Remove the original CSV file
    Remove-Item -Path $csvPath -Force
}

# pvTables
$TableNamesPV = @(    
    "processValueTable",
    "processValueStringTable"
)

# Dump data from tables into CSV files
foreach ($tableName in $TableNamesPV) {
    # Select oldest entry
    $oldestEntryQuery = "SELECT timestamp FROM ${tableName} ORDER BY timestamp LIMIT 1;"
    $oldestEntry = (psql -t -c $oldestEntryQuery $connectionString | Out-String).Trim()

    if ($oldestEntry) {
        $oldestTime = [datetime]::Parse($oldestEntry)
        $now = Get-Date

        while ($oldestTime -lt $now) {
            $iterationStart = $oldestTime.ToString("yyyy-MM-dd HH:mm:ss.ffffff")
            $iterStartFileName = $oldestTime.ToString("yyyy-MM-dd_HH-mm-ss.ffffff")
            $oldestTime = $oldestTime.AddDays(7)
            $iterationEnd = $oldestTime.ToString("yyyy-MM-dd HH:mm:ss.ffffff")

            Write-Host "Backing up $tableName from $iterationStart to $iterationEnd"
            $csvPath = "./timescale/tables/${tableName}_${iterStartFileName}.csv"

            $copyCommand = "\COPY (SELECT * FROM ${tableName} WHERE timestamp >= '${iterationStart}' AND timestamp < '${iterationEnd}') TO '${csvPath}' CSV"
            psql -c $copyCommand $connectionString
             
            # Create a zip archive for the CSV file
            $zipPath = "./timescale/tables/${tableName}_${iterStartFileName}.7z"
            & $SevenZipPath a -m0=zstd -mx0 -md=16m -mmt=on -mfb=64 "${csvPath}.7z" $csvPath

            # Remove the original CSV file
            Remove-Item -Path $csvPath -Force
        }
    } else {
        Write-Host "No data found in $tableName"
    }
}

# Dump post-data
pg_dump -U $User -h $Ip -p $Port -Fc -v --section=post-data --exclude-schema="_timescaledb*" -f ./timescale/dump_post_data.bak $Database


$env:PGPASSWORD = ""