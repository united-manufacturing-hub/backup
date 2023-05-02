param(
    [Parameter(Mandatory = $true)] # Path to the kubeconfig file
    [string]$KubeconfigPath = "",
    [Parameter(Mandatory = $true)] # Path to the backup folder
    [string]$BackupPath = ""
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

$IsEncrypted = $false
# Check if grafana_backup.7z.gpg exists and if so, decrypt it
if (Test-Path "$BackupPath\helm_backup.7z.gpg") {
    $IsEncrypted = $true
    Write-Host "Decrypting helm_backup.7z.gpg..."
    gpg --decrypt --output "$BackupPath\helm_backup.7z" "$BackupPath\helm_backup.7z.gpg"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "GPG decryption failed. Aborting the process."
        exit 1
    }
}

if (!(Test-Path "$BackupPath\helm_backup.7z")) {
    Write-Host "The backup folder $BackupPath does not contain a helm_backup.7z file."
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

    # Verify the hash of the helm_backup.7z file
    $HelmBackupFile = Join-Path $BackupPath "helm_backup.7z"
    $HelmBackupHash = ($FileHashes | Where-Object { $_.Path -eq "helm_backup.7z" }).Hash

    if (!(Verify-FileHash -FilePath $HelmBackupFile -ExpectedHash $HelmBackupHash))
    {
        Write-Host "Hash verification failed for helm_backup.7z. Aborting the process."
        exit 1
    }
}

$UnpackagedHelmPath = ".\helm"
$SevenZipPath = ".\_tools\7z.exe"
# Decompress the helm folder
& $SevenZipPath x -y -o"$UnpackagedHelmPath" "$BackupPath\helm_backup.7z" | Out-Null

# values.yaml file is in $UnpackagedHelmPath\helm\values.yaml

# Install the UMH helm chart
.\_tools\helm.exe repo add united-manufacturing-hub https://repo.umh.app/
.\_tools\helm.exe repo update

# Apply the values.yaml
.\_tools\helm.exe --kubeconfig $KubeconfigPath upgrade -n united-manufacturing-hub --atomic --values "$UnpackagedHelmPath\helm\values.yaml" united-manufacturing-hub united-manufacturing-hub/united-manufacturing-hub

# Remove unpackaged helm folder
Remove-Item -Path $UnpackagedHelmPath -Recurse -Force

if ($IsEncrypted){
    # Remove the decrypted 7z file
    Remove-Item -Path "${BackupPath}\helm_backup.7z" -Recurse -Force | Out-Nulls
}
