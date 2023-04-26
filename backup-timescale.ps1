param(
    [string]$Ip = "",
    [string]$Password = "",
    [int]$Port = 5432,
    [string]$User = "factoryinsight",
    [string]$Database = "factoryinsight",
    [string]$OutputPath = "."
)

if (!$Ip) {
    $Ip = Read-Host -Prompt "Enter the IP of your cluster:"
}

if (!$Password) {
    $Password = Read-Host -Prompt "Enter the password of your postgresql ($User) user:"
}

$ArchiveName = "${OutputPath}/timescale"
if (Test-Path $ArchiveName) {
    $overwrite = Read-Host -Prompt "The folder $ArchiveName already exists. Do you want to overwrite it? (y/N)"
    if ($overwrite.ToLower() -ne 'y') {
        Write-Host "Aborted. No changes have been made to the existing $ArchiveName."
        exit 1
    }

    Remove-Item -Path "${OutputPath}/timescale" -Recurse -Force
}
New-Item -Path $ArchiveName -ItemType Directory -Force | Out-Null
New-Item -Path "$ArchiveName/tables" -ItemType Directory -Force | Out-Null


# Set env variable for PGPASSWORD
$env:PGPASSWORD = $Password

# Get postgresql (SELECT version()) & timescaledb (\dx timescaledb) version

# Connect to the source database
$connectionString = "postgres://${User}:${Password}@${Ip}:${Port}/${Database}?sslmode=require"
$versionQuery = "SELECT version();"
$version = (psql -t -c $versionQuery $connectionString | Out-String).Trim()
$timescaleQuery = "SELECT installed_version FROM pg_available_extensions WHERE name = 'timescaledb';"
$timescaleVersion = (psql -t -c $timescaleQuery $connectionString | Out-String).Trim()

# Extract PostgreSQL version from the string
$version = $version -replace "PostgreSQL ([0-9]+\.[0-9]+).*", '$1'

Write-Host "Connected to $version"
Write-Host "TimescaleDB version: $timescaleVersion"

# Write version info to json file
$versionInfo = @{
    "postgresql" = $version
    "timescaledb" = $timescaleVersion
}
$versionInfo | ConvertTo-Json | Out-File -FilePath "$ArchiveName/version.json"

# Dump pre-data
pg_dump -U $User -h $Ip -p $Port -Fc -v --section=pre-data --exclude-schema="_timescaledb*" -f ${OutputPath}/timescale/dump_pre_data.bak $Database


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

# Updated foreach loop for parallel execution with a limit of 4 parallel jobs
$BackupJobScript = {
    param ($SevenZipPath, $OutputPath, $ArchiveName, $connectionString, $tableName)
    Write-Host "Backing up $tableName"
    $zipPath = "${OutputPath}/timescale/tables/${tableName}.7z"
    $copyCommand = "\COPY (SELECT * FROM ${tableName}) TO PROGRAM '7z.exe a -si${tableName}.csv -m0=zstd -mx0 -md=16m -mmt=on -mfb=64 ${zipPath}' CSV"
    psql -c $copyCommand $connectionString
}
$jobs = @()
$jobLimit = 4
foreach ($tableName in $TableNames) {
    while ($jobs.Count -ge $jobLimit) {
        $completed = $jobs | Where-Object { $_.State -eq 'Completed' }
        foreach ($job in $completed) {
            $jobs = $jobs | Where-Object { $_.Id -ne $job.Id }
            Receive-Job -Job $job
            Remove-Job -Job $job
        }
        Start-Sleep -Seconds 1
    }
    $job = Start-ThreadJob -ScriptBlock $BackupJobScript -ArgumentList $SevenZipPath, $OutputPath, $ArchiveName, $connectionString, $tableName
    $jobs += $job
}
# Wait for all jobs to complete
Wait-Job -Job $jobs
# Receive and clean up remaining jobs
foreach ($job in $jobs) {
    Receive-Job -Job $job
    Remove-Job -Job $job
}

# pvTables
$TableNamesPV = @(
    "processValueTable",
    "processValueStringTable"
)

# Dump data from tables into CSV files
# Updated second foreach loop with parallelized inner loop
$BackupPVJobScript = {
    param ($SevenZipPath, $OutputPath, $ArchiveName, $connectionString, $tableName, $iterationStart, $iterationEnd)
    Write-Host "Backing up $tableName from $iterationStart to $iterationEnd"
    $iterStartFileName = ([datetime]::Parse($iterationStart)).ToString("yyyy-MM-dd_HH-mm-ss.ffffff")
    $zipPath = "${OutputPath}/timescale/tables/${tableName}_${iterStartFileName}.7z"

    $copyCommand = "\COPY (SELECT * FROM ${tableName} WHERE timestamp >= '${iterationStart}' AND timestamp < '${iterationEnd}') TO PROGRAM '7z.exe a -si${tableName}_${iterStartFileName}.csv -m0=zstd -mx0 -md=16m -mmt=on -mfb=64 ${zipPath}' CSV"
    psql -c $copyCommand $connectionString
}

foreach ($tableName in $TableNamesPV) {
    # Select oldest entry
    $oldestEntryQuery = "SELECT timestamp FROM ${tableName} ORDER BY timestamp LIMIT 1;"
    $oldestEntry = (psql -t -c $oldestEntryQuery $connectionString | Out-String).Trim()

    if ($oldestEntry) {
        $oldestTime = [datetime]::Parse($oldestEntry)
        $now = Get-Date
        $timeRanges = @()

        while ($oldestTime -lt $now) {
            $iterationStart = $oldestTime.ToString("yyyy-MM-dd HH:mm:ss.ffffff")
            $oldestTime = $oldestTime.AddDays(7)
            $iterationEnd = $oldestTime.ToString("yyyy-MM-dd HH:mm:ss.ffffff")
            $timeRanges += ,@($iterationStart, $iterationEnd)
        }

        $jobs = @()
        $jobLimit = 4

        foreach ($timeRange in $timeRanges) {
            while ($jobs.Count -ge $jobLimit) {
                $completed = $jobs | Where-Object { $_.State -eq 'Completed' }
                foreach ($job in $completed) {
                    $jobs = $jobs | Where-Object { $_.Id -ne $job.Id }
                    Receive-Job -Job $job
                    Remove-Job -Job $job
                }
                Start-Sleep -Seconds 1
            }
            $job = Start-ThreadJob -ScriptBlock $BackupPVJobScript -ArgumentList $SevenZipPath, $OutputPath, $ArchiveName, $connectionString, $tableName, $timeRange[0], $timeRange[1]
            $jobs += $job
        }

        # Wait for all jobs to complete
        Wait-Job -Job $jobs
        # Receive and clean up remaining jobs
        foreach ($job in $jobs) {
            Receive-Job -Job $job
            Remove-Job -Job $job
        }
    } else {
        Write-Host "No data found in $tableName"
    }
}

# Go trough tables folder and clean up every .csv file, that might be left over
Get-ChildItem -Path "${OutputPath}/timescale/tables" -Filter "*.csv" | Remove-Item -Force

# Dump post-data
pg_dump -U $User -h $Ip -p $Port -Fc -v --section=post-data --exclude-schema="_timescaledb*" -f ${OutputPath}/timescale/dump_post_data.bak $Database

$env:PGPASSWORD = ""


Write-Host "Backup of timescale database complete."
