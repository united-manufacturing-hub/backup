param(
    [Parameter(Mandatory = $true)] # Path to the kubeconfig file
    [string]$KubeconfigPath = "",
    [Parameter(Mandatory = $true)] # Path to the backup folder
    [string]$BackupPath = ""
)

$Namespace = "mgmtcompanion"
$StatefulsetName = "mgmtcompanion"
$SecretName = "mgmtcompanion-secret"
$ConfigmapName = "mgmtcompanion-config"

# Check if the backup folder exists and contains helm_backup.7z
if (!(Test-Path $BackupPath)) {
    Write-Host "The backup folder $BackupPath does not exist."
    exit 1
}

$IsEncrypted = $false
# Check if companion_backup.7z.gpg exists and if so, decrypt it
if (Test-Path "$BackupPath\companion_backup.7z.gpg") {
    $IsEncrypted = $true
    Write-Host "Decrypting companion_backup.7z.gpg..."
    gpg --decrypt --output "$BackupPath\companion_backup.7z" "$BackupPath\companion_backup.7z.gpg"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "GPG decryption failed. Aborting the process."
        exit 1
    }
}

if (!(Test-Path "$BackupPath\companion_backup.7z")) {
    Write-Host "The backup folder $BackupPath does not contain a companion_backup.7z file."
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

    # Verify the hash of the companion_backup.7z file
    $CompanionBackupFile = Join-Path $BackupPath "companion_backup.7z"
    $CompanionBackupHash = ($FileHashes | Where-Object { $_.Path -eq "companion_backup.7z" }).Hash

    if (!(Verify-FileHash -FilePath $CompanionBackupFile -ExpectedHash $CompanionBackupHash))
    {
        Write-Host "Hash verification failed for companion_backup.7z. Aborting the process."
        exit 1
    }
}

$UnpackagedCompanionPath = ".\companion"
$SevenZipPath = ".\_tools\7z.exe"

# Decompress the helm folder
& $SevenZipPath x -y -o"$UnpackagedCompanionPath" "$BackupPath\companion_backup.7z" | Out-Null

Write-Host "Restore companion: Delete configmap"
.\_tools\kubectl.exe --kubeconfig $kubeconfigPath -n $Namespace delete configmap $ConfigmapName
.\_tools\kubectl.exe apply -f ".\companion\${ConfigmapName}.yaml"

Write-Host "Restore companion: Delete secret"
.\_tools\kubectl.exe --kubeconfig $kubeconfigPath -n $Namespace delete secret $SecretName
.\_tools\kubectl.exe apply -f ".\companion\${SecretName}.yaml"

Write-Host "Restore companion: Delete statefulset"
.\_tools\kubectl.exe --kubeconfig $kubeconfigPath -n $Namespace delete statefulset $StatefulsetName
.\_tools\kubectl.exe apply -f ".\companion\${StatefulsetName}.yaml"

# Remove unpackaged companion folder
Remove-Item -Path $UnpackagedCompanionPath -Recurse -Force

if ($IsEncrypted){
    # Remove the decrypted 7z file
    Remove-Item -Path "${BackupPath}\companion_backup.7z" -Recurse -Force | Out-Nulls
}