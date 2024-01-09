param(
    [string]$Ip = "",
    [string]$Password = "",
    [string]$PasswordV2 = "", 
    [int]$Port = 5432,
    [string]$User = "factoryinsight",
    [string]$Database = "factoryinsight",
    [string]$UserV2 = "kafkatopostgresqlv2",
    [string]$DatabaseV2 = "umh_v2",
    [string]$OutputPath = ".",
    [int]$ParallelJobs = 4,
    [int]$DaysPerJob = 31
)

if (!$Ip) {
    $Ip = Read-Host -Prompt "Enter the IP of your cluster:"
}

if (!$Password) {
    $Password = Read-Host -Prompt "Enter the password of your postgresql ($User) user:"
}

if (!$PasswordV2) {
    $PasswordV2 = Read-Host -Prompt "Enter the password of your postgresql ($UserV2) user:"
}

if (Get-Command -ErrorAction Ignore -Type Cmdlet Start-ThreadJob) {
    Write-Host "Module 'ThreadJob' is already installed."
}else{
    Write-Verbose "Installing module 'ThreadJob' on demand..."
    Install-Module -ErrorAction Stop -Scope CurrentUser ThreadJob
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
New-Item -Path "$ArchiveName/tables/$Database" -ItemType Directory -Force | Out-Null
New-Item -Path "$ArchiveName/tables/$DatabaseV2" -ItemType Directory -Force | Out-Null

# Set env variable for PGPASSWORD
$env:PGPASSWORD = $Password

# Get postgresql (SELECT version()) & timescaledb (\dx timescaledb) version

# Connect to the source database
$connectionString = "postgres://${User}:${Password}@${Ip}:${Port}/${Database}?sslmode=require"
$connectionStringV2 = "postgres://${UserV2}:${PasswordV2}@${Ip}:${Port}/${DatabaseV2}?sslmode=require"
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
pg_dump -U $User -h $Ip -p $Port -Fc -v --section=pre-data --exclude-schema="_timescaledb*" -f ${OutputPath}/timescale/dump_pre_data_factoryinsight.bak $Database


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

Write-Host "Backing up tables"
$BackupJobScript = {
    param ($SevenZipPath, $OutputPath, $ArchiveName, $connectionString, $dataBase, $tableName)
    Write-Host "Backing up $tableName"
    $csvPath = "${OutputPath}/timescale/tables/${dataBase}/${tableName}.csv"
    $zipPath = "${OutputPath}/timescale/tables/${dataBase}/${tableName}.7z"
    $copyCommand = "\COPY (SELECT * FROM ${tableName}) TO '${csvPath}' CSV"
    psql -c $copyCommand $connectionString

    # Create a zip archive for the CSV file
    & $SevenZipPath a -m0=zstd -mx0 -md=16m -mmt=on -mfb=64 "${zipPath}" $csvPath | Out-Null

    # Remove the original CSV file
    Remove-Item -Path $csvPath -Force
}

$jobs = New-Object System.Collections.ArrayList
foreach ($tableName in $TableNames) {
    while ($jobs.Count -ge $ParallelJobs) {
        $completed = $jobs | Where-Object { $_.State -eq 'Completed' }
        foreach ($job in $completed) {
            $jobs.Remove($job) | Out-Null
            Receive-Job -Job $job
            Remove-Job -Job $job
        }
        Start-Sleep -Seconds 1
    }
    $job = Start-ThreadJob -ScriptBlock $BackupJobScript -ArgumentList $SevenZipPath, $OutputPath, $ArchiveName, $connectionString, $Database, $tableName
    $jobs.Add($job) | Out-Null
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

Write-Host "Backing up processValueTables"
$BackupPVJobScript = {
    param ($SevenZipPath, $OutputPath, $ArchiveName, $connectionString, $dataBase, $tableName, $iterationStart, $iterationEnd)
    Write-Host "Backing up $tableName from $iterationStart to $iterationEnd"
    $iterStartFileName = ([datetime]::Parse($iterationStart)).ToString("yyyy-MM-dd_HH-mm-ss.ffffff")
    $csvPath = "${OutputPath}/timescale/tables/${dataBase}/${tableName}_${iterStartFileName}.csv"
    $zipPath = "${OutputPath}/timescale/tables/${dataBase}/${tableName}_${iterStartFileName}.7z"

    $copyCommand = "\COPY (SELECT * FROM ${tableName} WHERE timestamp >= '${iterationStart}' AND timestamp < '${iterationEnd}') TO '${csvPath}' CSV"
    psql -c $copyCommand $connectionString

    # Create a zip archive for the CSV file
    & $SevenZipPath a -m0=zstd -mx0 -md=16m -mmt=on -mfb=64 "${zipPath}" $csvPath | Out-Null

    # Remove the original CSV file
    Remove-Item -Path $csvPath -Force
}


$jobsPV = New-Object System.Collections.ArrayList
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
            $oldestTime = $oldestTime.AddDays($DaysPerJob)
            $iterationEnd = $oldestTime.ToString("yyyy-MM-dd HH:mm:ss.ffffff")
            $timeRanges += ,@($iterationStart, $iterationEnd)
        }

        foreach ($timeRange in $timeRanges) {
            while ($jobsPV.Count -ge $ParallelJobs) {
                $completed = $jobsPV | Where-Object { $_.State -eq 'Completed' }
                foreach ($job in $completed) {
                    $jobsPV.Remove($job) | Out-Null
                    Receive-Job -Job $job
                    Remove-Job -Job $job
                }
                Start-Sleep -Seconds 1
            }
            $job = Start-ThreadJob -ScriptBlock $BackupPVJobScript -ArgumentList $SevenZipPath, $OutputPath, $ArchiveName, $connectionString, $Database, $tableName, $timeRange[0], $timeRange[1]
            $jobsPV.Add($job) | Out-Null
        }

        # Wait for all jobs to complete
        Wait-Job -Job $jobsPV
        # Receive and clean up remaining jobs
        foreach ($job in $jobsPV) {
            Receive-Job -Job $job
            Remove-Job -Job $job
        }
    } else {
        Write-Host "No data found in $tableName"
    }
}

# Dump post-data
pg_dump -U $User -h $Ip -p $Port -Fc -v --section=post-data --exclude-schema="_timescaledb*" -f ${OutputPath}/timescale/dump_post_data_factoryinsight.bak $Database

# UMH_V2

# Set env variable for PGPASSWORD
$env:PGPASSWORD = $PasswordV2

# Dump pre-data
pg_dump -U $UserV2 -h $Ip -p $Port -Fc -v --section=pre-data --exclude-schema="_timescaledb*" -f ${OutputPath}/timescale/dump_pre_data_v2.bak $DatabaseV2

# Predefined table names
$TableAssetV2 = "asset"

Write-Host "Backing up tables (umh_v2)"
Get-Location

$csvPath = "${OutputPath}/timescale/tables/${DatabaseV2}/${TableAssetV2}.csv"
    $zipPath = "${OutputPath}/timescale/tables/${DatabaseV2}/${TableAssetV2}.7z"
    $copyCommand = "\COPY (SELECT * FROM ${TableAssetV2}) TO '${csvPath}' CSV"
    psql -c $copyCommand $connectionStringV2

    # Create a zip archive for the CSV file
    & $SevenZipPath a -m0=zstd -mx0 -md=16m -mmt=on -mfb=64 "${zipPath}" $csvPath | Out-Null

    # Remove the original CSV file
    Remove-Item -Path $csvPath -Force


# tag table in umh_v2
$TableNamesTagV2 = @(
    "tag",
    "tag_string"
)

Write-Host "Backing up tag tables (umh_v2)"

$jobsPV = New-Object System.Collections.ArrayList
foreach ($tableName in $TableNamesTagV2) {
    # Select oldest entry
    $oldestEntryQuery = "SELECT timestamp FROM ${tableName} ORDER BY timestamp LIMIT 1;"
    $oldestEntry = (psql -t -c $oldestEntryQuery $connectionStringV2 | Out-String).Trim()

    if ($oldestEntry) {
        $oldestTime = [datetime]::Parse($oldestEntry)
        $now = Get-Date
        $timeRanges = @()

        while ($oldestTime -lt $now) {
            $iterationStart = $oldestTime.ToString("yyyy-MM-dd HH:mm:ss.ffffff")
            $oldestTime = $oldestTime.AddDays($DaysPerJob)
            $iterationEnd = $oldestTime.ToString("yyyy-MM-dd HH:mm:ss.ffffff")
            $timeRanges += ,@($iterationStart, $iterationEnd)
        }

        foreach ($timeRange in $timeRanges) {
            while ($jobsPV.Count -ge $ParallelJobs) {
                $completed = $jobsPV | Where-Object { $_.State -eq 'Completed' }
                foreach ($job in $completed) {
                    $jobsPV.Remove($job) | Out-Null
                    Receive-Job -Job $job
                    Remove-Job -Job $job
                }
                Start-Sleep -Seconds 1
            }
            $job = Start-ThreadJob -ScriptBlock $BackupPVJobScript -ArgumentList $SevenZipPath, $OutputPath, $ArchiveName, $connectionStringV2, $DatabaseV2, $tableName, $timeRange[0], $timeRange[1]
            $jobsPV.Add($job) | Out-Null
        }

        # Wait for all jobs to complete
        Wait-Job -Job $jobsPV
        # Receive and clean up remaining jobs
        foreach ($job in $jobsPV) {
            Receive-Job -Job $job
            Remove-Job -Job $job
        }
    } else {
        Write-Host "No data found in $tableName"
    }
}

# Dump post-data
pg_dump -U $UserV2 -h $Ip -p $Port -Fc -v --section=post-data --exclude-schema="_timescaledb*" -f ${OutputPath}/timescale/dump_post_data_v2.bak $DatabaseV2

# Go trough tables folder and clean up every .csv file, that might be left over
Get-ChildItem -Path "${OutputPath}/timescale/tables/${Database}" -Filter "*.csv" | Remove-Item -Force
Get-ChildItem -Path "${OutputPath}/timescale/tables/${DatabaseV2}" -Filter "*.csv" | Remove-Item -Force

$env:PGPASSWORD = ""

Write-Host "Backup of timescale database complete."
