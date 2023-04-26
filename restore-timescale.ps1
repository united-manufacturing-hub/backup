param(
    [string]$Ip = "",
    [int]$Port = 5432,
    [string]$User = "factoryinsight",
    [string]$Database = "factoryinsight",
    [string]$BackupPath = "",
    [string]$PatroniSuperUserPassword = "",
    [Boolean]$IKnowWhatImDoing = $false
)

if (!$Ip) {
    $Ip = Read-Host -Prompt "Enter the IP of your cluster:"
}

if (!$PatroniSuperUserPassword) {
    $PatroniSuperUserPassword = Read-Host -Prompt "Enter the password of your postgresql user:"
}


# Check if the backup folder exists and contains helm_backup.7z
if (!(Test-Path $BackupPath)) {
    Write-Host "The backup folder $BackupPath does not exist."
    exit 1
}

if (!(Test-Path "$BackupPath\timescale")) {
    Write-Host "The backup folder $BackupPath does not contain a timescale file."
    exit 1
}

# Read the version.json file to get the postgresql and timescaledb versions
$versionInfo = Get-Content "$BackupPath\timescale\version.json" | ConvertFrom-Json

# Connect to the source database
$connectionStringPG = "postgres://postgres:${PatroniSuperUserPassword}@${Ip}:${Port}/postgres?sslmode=require"
$connectionStringFC = "postgres://postgres:${PatroniSuperUserPassword}@${Ip}:${Port}/factoryinsight?sslmode=require"

$versionQuery = "SELECT version();"
$version = (psql -t -c $versionQuery $connectionStringPG | Out-String).Trim()
$timescaleQuery = "SELECT installed_version FROM pg_available_extensions WHERE name = 'timescaledb';"
$timescaleVersion = (psql -t -c $timescaleQuery $connectionStringPG | Out-String).Trim()
# Extract PostgreSQL version from the string
$version = $version -replace "PostgreSQL ([0-9]+\.[0-9]+).*", '$1'

## Extract major versions
$version = $version -replace "([0-9]+\.[0-9]+).*", '$1'
$versionInfo.postgresql = $versionInfo.postgresql -replace "([0-9]+\.[0-9]+).*", '$1'
$versionInfo.timescaledb = $versionInfo.timescaledb -replace "([0-9]+\.[0-9]+).*", '$1'
$timescaleVersion = $timescaleVersion -replace "([0-9]+\.[0-9]+).*", '$1'

if ($version -ne $versionInfo.postgresql) {
    Write-Host "The major versions of PostgreSQL do not match. Aborting."
    Write-Host "Source: $versionInfo.postgresql"
    Write-Host "Target: $version"
    exit 1
}

if ($timescaleVersion -ne $versionInfo.timescaledb) {
    Write-Host "The major versions of TimescaleDB do not match. Aborting."
    Write-Host "Source: $versionInfo.timescaledb"
    Write-Host "Target: $timescaleVersion"
    exit 1
}

if ($IKnowWhatImDoing -ne $true)
{
    Write-Host "[WARN] This script will delete and recreate the database $Database ($Ip). Press Y to continue."
    $continue = Read-Host -Prompt "Continue? (y/N)"
    if ($continue.ToLower() -ne 'y')
    {
        Write-Host "Aborted. No changes have been made to the existing $Database."
        exit 1
    }

    Write-Host "[WARN] Ensure no other write operations are running on the database. Press Y to continue."
    $continue = Read-Host -Prompt "Continue? (y/N)"
    if ($continue.ToLower() -ne 'y')
    {
        Write-Host "Aborted. No changes have been made to the existing $Database."
        exit 1
    }


    Write-Host "[WARN] Last chance to abort. This script will delete and recreate the database $Database ($Ip). Write "delete" to continue."
    $continue = Read-Host -Prompt "Continue?"
    if ($continue.ToLower() -ne 'delete')
    {
        Write-Host "Aborted. No changes have been made to the existing $Database."
        exit 1
    }
}



### Check if go is available
$go = Get-Command go -ErrorAction SilentlyContinue
$canUsePCopy = $false
$numCPU = (Get-WmiObject -Class Win32_Processor).NumberOfLogicalProcessors
$numThreads = $numCPU * 2
if ($go -eq $null) {
    Write-Host "go is not available. Will use COPY instead of timescaledb-parallel-copy"
}else{
    Write-Host "go is available. Will use timescaledb-parallel-copy"
    go install github.com/timescale/timescaledb-parallel-copy/cmd/timescaledb-parallel-copy@latest
    $canUsePCopy = $trues
}

# Terminate all connections to the database
Write-Host "Terminating all connections to database $Database..."
$revokeConnectionsQuery = "SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.datname = '$Database';"
psql -t -c $revokeConnectionsQuery $connectionStringFC

# Drop the database
Write-Host "Dropping database $Database..."
$dropQuery = "DROP DATABASE $Database;"
psql -t -c $dropQuery $connectionStringPG

# Create the database
Write-Host "Creating database $Database..."
$createQuery = "CREATE DATABASE $Database OWNER $User;"
psql -t -c $createQuery $connectionStringPG

$grantQuery = "GRANT ALL PRIVILEGES ON DATABASE $Database TO $User;"
psql -t -c $grantQuery $connectionStringPG

# Restore the database

# Set env variable for PGPASSWORD
$env:PGPASSWORD = $PatroniSuperUserPassword

Write-Host "Restoring database $Database..."
## Restore pre-data
Write-Host "Restoring pre-data..."
# pg_restore -U postgres -w -h <HOST> -p <PORT> --no-owner -Fc -v -d tsdb dump_pre_data.bak
pg_restore -U postgres -w -h $Ip -p $Port --no-owner -Fc -v -d $Database "$BackupPath\timescale\dump_pre_data.bak"

## Restore hypertables
Write-Host "Restoring hypertables..."
$HyperTablesTS = @(
    "stateTable",
    "countTable",
    "processValueTable",
    "processValueStringTable"
)

foreach ($tableName in $HyperTablesTS) {
    Write-Host "Recreating hypertable ($tableName)..."
    # SELECT create_hypertable('<TABLE_NAME>', 'timestamp');
    $createHyperTableQuery = "SELECT create_hypertable('$tableName', 'timestamp');"
    psql -t -c $createHyperTableQuery $connectionStringFC
}

$HyperTablesPUID = @(
    "productTagTable",
    "productTagStringTable"
)

foreach ($tableName in $HyperTablesPUID) {
    Write-Host "Recreating hypertable ($tableName)..."
    # SELECT create_hypertable('<TABLE_NAME>', 'product_uid');
    $createHyperTableQuery = "SELECT create_hypertable('$tableName', 'product_uid', chunk_time_interval => 100000);"
    psql -t -c $createHyperTableQuery $connectionStringFC
}

## Restore data
Write-Host "Restoring data..."

$SevenZipPath = ".\_tools\7z.exe"

### For each .7z file in the backup folder\timescale\tables
### Create temp folder (./tables)
New-Item -ItemType Directory -Force -Path ".\tables" | Out-Null
$files = Get-ChildItem "$BackupPath\timescale\tables" -Filter *.7z
foreach ($file in $files) {
    # Delete all file from the temp folder
    Remove-Item -Path ".\tables\*" -Force
    Write-Host "Restoring file $file..."
    $fileName = $file.Name
    & $SevenZipPath x "$BackupPath\timescale\tables\$fileName" -o".\tables" -y | Out-Null

    ### For each file in the temp folder
    $fx = Get-ChildItem ".\tables" -Filter *.csv
    foreach ($fileX in $fx){
        $fileNameX = $fileX.Name
        ## Get tableName, by removing the .csv extension
        $tableName = $fileNameX -replace "\.csv", ''
        ### Also remove the time suffix (_YYYY-MM-DD_HH-MM-SS.ffffff)
        $tableName = $tableName -replace "_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.[0-9]{6}", ''
        Write-Host "Restoring table $tableName..."
        ### Restore the table

        if ($canUsePCopy){
            # timescaledb-parallel-copy \
            #--connection "host=<HOST> \
            #user=tsdbadmin password=<PASSWORD> \
            #port=<PORT> \
            #sslmode=require" \
            #--db-name tsdb \
            #--table <TABLE_NAME> \
            #--file <FILE_NAME>.csv \
            #--workers <NUM_WORKERS> \
            #--reporting-period 30s
            timescaledb-parallel-copy --connection "host=$Ip user=postgres password=$PatroniSuperUserPassword port=$Port sslmode=require" --db-name $Database --table $tableName --file $fileX --workers $numThreads --reporting-period 30s
        }else
        {
            #### \COPY <TABLE_NAME> FROM '<TABLE_NAME>.csv' WITH (FORMAT CSV);
            $copyQuery = "\COPY $tableName FROM '$fileX' WITH (FORMAT CSV);"
            psql -t -c $copyQuery $connectionStringFC
        }
    }
}
# Remove the temp folder
Remove-Item -Path ".\tables" -Force -Recurse

Write-Host "Restored Tables"

## Restore post-data
Write-Host "Restoring post-data..."
### pg_restore -U tsdbadmin -w -h <HOST> -p <PORT> --no-owner -Fc -v -d tsdb dump_post_data.bak
$restoreOutput = pg_restore -U postgres -w -h $Ip -p $Port --no-owner -Fc -v -d $Database "$BackupPath\timescale\dump_post_data.bak" 2>&1

$pattern = 'ALTER TABLE ONLY public.\w+\s+.*?;'
$matches = [regex]::Matches($restoreOutput, $pattern)

$erroredCommands = $matches | ForEach-Object { $_.Value }

Write-Host "Error commands:"
$erroredCommands | ForEach-Object {
    ## Remove ONLY from the command
    $command = $_ -replace "ONLY", ''
    ## Execute the command
    psql -t -c $command $connectionStringFC
}


Write-Host "Restored post-data"
Write-Host "Restored database $Database"

$env:PGPASSWORD = ""
