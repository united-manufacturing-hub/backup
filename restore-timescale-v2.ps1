param(
    [Parameter(Mandatory = $true)] # IP of the cluster
    [string]$Ip = "",
    [Parameter(Mandatory = $false)] # Port of the cluster
    [int]$Port = 5432,
    [Parameter(Mandatory = $false)] # User of the cluster
    [string]$User = "kafkatopostgresqlv2",
    [Parameter(Mandatory = $false)] # Database of the cluster
    [string]$Database = "umh_v2",
    [Parameter(Mandatory = $true)] # Path to the backup folder
    [string]$BackupPath = "",
    [Parameter(Mandatory = $true)] # Password of the postgresql user
    [string]$PatroniSuperUserPassword = "",
    [Parameter(Mandatory = $false)] # I know what I'm doing
    [Boolean]$IKnowWhatImDoing = $false
)

if (Get-Command -ErrorAction Ignore -Type Cmdlet Start-ThreadJob) {
    Write-Host "Module 'ThreadJob' is already installed."
}else{
    Write-Verbose "Installing module 'ThreadJob' on demand..."
    Install-Module -ErrorAction Stop -Scope CurrentUser ThreadJob
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
# Verify GPG signature
$SignedFile = Join-Path $BackupPath "file_hashes.json"
$SignatureFile = Join-Path $BackupPath "file_hashes.json.sig"

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

function Decrypt-File($InputFile, $OutputFile) {
    gpg --decrypt --output $OutputFile $InputFile > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "GPG decryption failed for $InputFile. Aborting the process."
        exit 1
    }
    return $OutputFile
}


if ($CheckGPG) {
    gpg --verify $SignatureFile $SignedFile
    if ($LASTEXITCODE -ne 0) {
        Write-Host "GPG signature verification failed. Aborting the process."
        exit 1
    }

    # Load the JSON file with the file hashes
    $FileHashes = (Get-Content -Path $SignedFile | ConvertFrom-Json).Files

    function Verify-FileHash($FilePath, $ExpectedHash) {
        $IsEncrypted = $false
        # Check if file ends with .gpg
        if ($FilePath.EndsWith(".gpg")) {
            $IsEncrypted = $true
            # New path is the same without the .gpg extension
            $OutFile = $FilePath.Substring(0, $FilePath.Length - 4)
            # Decrypt the file
            $FilePath = Decrypt-File -InputFile $FilePath -OutputFile $OutFile
        }
        $ActualHash = (Get-FileHash -Path $FilePath -Algorithm SHA512).Hash
        if ($IsEncrypted){
            # Delete the decrypted file
            Remove-Item $FilePath
        }
        return $ActualHash -eq $ExpectedHash
    }

    # Verify the hash of the timescale backup files
    $TimescaleFolderPath = Join-Path $BackupPath "timescale"
    $BackupFiles = Get-ChildItem -Path $TimescaleFolderPath -Recurse -File
    $BackupFilesCnt = $BackupFiles.Count

    Write-Host "Verifying $BackupFilesCnt files..."
    if ($BackupFilesCnt -eq 0) {
        Write-Host "No files found in the timescale folder. Aborting the process."
        exit 1
    }

    foreach ($BackupFile in $BackupFiles) {
        $RelativePath = $BackupFile.FullName.Substring($TimescaleFolderPath.Length + 1)
        Write-Host "Verifing ${BackupFile}"
        # If $RelativePath ends with .gpg, remove the extension for the hash lookup
        $ActualRelativePath = $RelativePath
        if ($RelativePath.EndsWith(".gpg")) {
            $ActualRelativePath = $RelativePath.Substring(0, $RelativePath.Length - 4)
        }
        $ExpectedHash = ($FileHashes | Where-Object { $_.Path -eq "timescale\$ActualRelativePath" }).Hash

        if (!$ExpectedHash) {
            Write-Host "File $ActualRelativePath is not part of the hash database. Aborting the process."
            exit 1
        }

        if ($CheckGPG -and !(Verify-FileHash -FilePath $BackupFile.FullName -ExpectedHash $ExpectedHash)) {
            Write-Host "Hash verification failed for $RelativePath. Aborting the process."
            exit 1
        }
    }
    Write-Host "Verified $BackupFilesCnt files."
    Write-Host "GPG signature and hash verification passed."
}


$AssumeEncryption = $false
# Check if version.json.gpg exists
if (Test-Path "$BackupPath\timescale\version.json.gpg") {
    $AssumeEncryption = $true
    Write-Host "Found encrypted version.json, assuming encryption"
}

if ($AssumeEncryption){
    # Decrypt the version.json file
    Decrypt-File -InputFile "$BackupPath\timescale\version.json.gpg" -OutputFile "$BackupPath\timescale\version.json"
    $versionInfo = Get-Content "$BackupPath\timescale\version.json" | ConvertFrom-Json
    Remove-Item "$BackupPath\timescale\version.json"
}else
{
    # Read the version.json file to get the postgresql and timescaledb versions
    $versionInfo = Get-Content "$BackupPath\timescale\version.json" | ConvertFrom-Json
}

# Connect to the source database
$connectionStringPG = "postgres://postgres:${PatroniSuperUserPassword}@${Ip}:${Port}/postgres?sslmode=require"
$connectionStringV2 = "postgres://postgres:${PatroniSuperUserPassword}@${Ip}:${Port}/umh_v2?sslmode=require"

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
psql -t -c $revokeConnectionsQuery $connectionStringV2

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
if ($AssumeEncryption){
    # Decrypt the dump_pre_data.bak file
    Decrypt-File -InputFile "$BackupPath\timescale\dump_pre_data_v2.bak.gpg" -OutputFile "$BackupPath\timescale\dump_pre_data_v2.bak"
    pg_restore -U postgres -w -h $Ip -p $Port --no-owner -Fc -v -d $Database "$BackupPath\timescale\dump_pre_data_v2.bak"
    Remove-Item "$BackupPath\timescale\dump_pre_data_v2.bak"
}else
{
    pg_restore -U postgres -w -h $Ip -p $Port --no-owner -Fc -v -d $Database "$BackupPath\timescale\dump_pre_data_v2.bak"
}

## Restore hypertables
Write-Host "Restoring hypertables..."
$HyperTablesTS = @(
    "tag",
    "tag_string"
)

foreach ($tableName in $HyperTablesTS) {
    Write-Host "Recreating hypertable ($tableName)..."
    # SELECT create_hypertable('<TABLE_NAME>', 'timestamp');
    $createHyperTableQuery = "SELECT create_hypertable('$tableName', 'timestamp');"
    psql -t -c $createHyperTableQuery $connectionStringV2
}

## Restore data
Write-Host "Restoring data..."

$SevenZipPath = ".\_tools\7z.exe"

### For each .7z file in the backup folder\timescale\tables
### Create temp folder (./tables)
New-Item -ItemType Directory -Force -Path ".\tables" | Out-Null
New-Item -ItemType Directory -Force -Path ".\tables\umh_v2" | Out-Null
$files = Get-ChildItem "$BackupPath\timescale\tables\umh_v2" -Filter *.7z
if ($AssumeEncryption){
    $files = Get-ChildItem "$BackupPath\timescale\tables\umh_v2" -Filter *.7z.gpg
}
foreach ($file in $files) {
    # Delete all file from the temp folder
    Remove-Item -Path ".\tables\umh_v2\*" -Force
    Write-Host "Restoring file $file..."
    $fileName = $file.Name

    if ($AssumeEncryption){
        # Decrypt the file (don't forget to remove the .gpg extension)
        $fileNameWithoutExtension = $fileName -replace "\.gpg", ''
        Decrypt-File -InputFile "$BackupPath\timescale\tables\umh_v2\$fileName" -OutputFile "$BackupPath\timescale\tables\umh_v2\$fileNameWithoutExtension"
        $fileName = $fileNameWithoutExtension
    }

    & $SevenZipPath x "$BackupPath\timescale\tables\umh_v2\$fileName" -o".\tables\umh_v2" -y | Out-Null

    ### For each file in the temp folder
    $fx = Get-ChildItem ".\tables\umh_v2" -Filter *.csv
    Set-Location .\tables\umh_v2
    foreach ($fileX in $fx){
        $fileNameX = $fileX.Name
        ## Get tableName, by removing the .csv extension
        $tableName = $fileNameX -replace "\.csv", ''
        ### Also remove the time suffix (_YYYY-MM-DD_HH-MM-SS.ffffff)
        Write-Host "Restoring table $tableName..."
        $tableName = $tableName -replace "_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.[0-9]{6}", ''
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
            psql -t -c $copyQuery $connectionStringV2
        }
    }

    Set-Location ..\..\

    if ($AssumeEncryption){
        # Remove the decrypted file
        Remove-Item "$BackupPath\timescale\tables\umh_v2\$fileName"
    }
}
# Remove the temp folder
Remove-Item -Path ".\tables" -Force -Recurse

Write-Host "Restored Tables"

## Restore post-data
Write-Host "Restoring post-data..."
$restoreOutput = ""
if ($AssumeEncryption){
    Decrypt-File -InputFile "$BackupPath\timescale\dump_post_data_v2.bak.gpg" -OutputFile "$BackupPath\timescale\dump_post_data_v2.bak"
    $restoreOutput = pg_restore -U postgres -w -h $Ip -p $Port --no-owner -Fc -v -d $Database "$BackupPath\timescale\dump_post_data_v2.bak" 2>&1
    Remove-Item "$BackupPath\timescale\dump_post_data_v2.bak"
}else
{
    $restoreOutput = pg_restore -U postgres -w -h $Ip -p $Port --no-owner -Fc -v -d $Database "$BackupPath\timescale\dump_post_data_v2.bak" 2>&1
}

$pattern = 'ALTER TABLE ONLY public.\w+\s+.*?;'
$matches = [regex]::Matches($restoreOutput, $pattern)

$erroredCommands = $matches | ForEach-Object { $_.Value }

Write-Host "Error commands:"
$erroredCommands | ForEach-Object {
    ## Remove ONLY from the command
    $command = $_ -replace "ONLY", ''
    ## Execute the command
    psql -t -c $command $connectionStringV2
}


Write-Host "Restored post-data"

$cmdAnalyze = "ANALYZE;"
psql -c $cmdAnalyze $connectionStringPG | Out-Null

Write-Host "Restored database $Database"

$env:PGPASSWORD = ""
