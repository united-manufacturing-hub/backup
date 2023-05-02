param(
    [Parameter(Mandatory = $true)] # Path to the kubeconfig file
    [string]$KubeconfigPath = "",
    [Parameter(Mandatory = $true)] # Path to the backup folder
    [string]$BackupPath = ""
)

function KubectlCopyToServer($kubeconfigPath, $namespace, $srcPath, $podName, $destPath) {
    # Ignore errors here
    .\_tools\kubectl.exe --kubeconfig $kubeconfigPath -n $namespace cp $srcPath "${podName}:${destPath}" | Out-Null
}

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
if (Test-Path "$BackupPath\nodered_backup.7z.gpg") {
    $IsEncrypted = $true
    Write-Host "Decrypting nodered_backup.7z.gpg..."
    gpg --decrypt --output "$BackupPath\nodered_backup.7z" "$BackupPath\nodered_backup.7z.gpg"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "GPG decryption failed. Aborting the process."
        exit 1
    }
}

if (!(Test-Path "$BackupPath\nodered_backup.7z")) {
    Write-Host "The backup folder $BackupPath does not contain a nodered_backup.7z file."
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
    $HelmBackupFile = Join-Path $BackupPath "nodered_backup.7z"
    $HelmBackupHash = ($FileHashes | Where-Object { $_.Path -eq "nodered_backup.7z" }).Hash

    if (!(Verify-FileHash -FilePath $HelmBackupFile -ExpectedHash $HelmBackupHash))
    {
        Write-Host "Hash verification failed for nodered_backup.7z. Aborting the process."
        exit 1
    }
}

$UnpackagedNodeRedPath = ".\nodered"
$SevenZipPath = ".\_tools\7z.exe"
# Decompress the helm folder
& $SevenZipPath x -y -o"$UnpackagedNodeRedPath" "$BackupPath\nodered_backup.7z" | Out-Null

# for each file in ./nodered/nodered folder
foreach ($file in Get-ChildItem -Path "$UnpackagedNodeRedPath\nodered") {
    # copy the file to the server
    Write-Host "Copying $file to the server"
    # Get name of $file
    $file = $file.Name
    if ($file -eq "settings.js") {
        Write-Host "Skipping settings.js (set by helm)"
        continue
    }
    KubectlCopyToServer -kubeconfigPath $KubeconfigPath -namespace "united-manufacturing-hub" -srcPath "${UnpackagedNodeRedPath}\nodered\$file" -podName "united-manufacturing-hub-nodered-0" -destPath "/data/$file"
}

Write-Host "Restored config files to the server. Restarting nodered pod."

# Restart the nodered pod
.\_tools\kubectl.exe --kubeconfig $KubeconfigPath -n united-manufacturing-hub delete pod united-manufacturing-hub-nodered-0

# Remove unpackaged nodered folder
Remove-Item -Path $UnpackagedNodeRedPath -Recurse -Force

if ($IsEncrypted){
    # Remove the decrypted 7z file
    Remove-Item -Path "${BackupPath}\nodered_backup.7z" -Recurse -Force | Out-Nulls
}
