param(
    [string]$KubeconfigPath = "",
    [string]$BackupPath = ""
)

if (!$BackupPath) {
    $BackupPath = Read-Host -Prompt "Enter the Path to your backup folder:"
}

if (!$KubeconfigPath) {
    $KubeconfigPath = Read-Host -Prompt "Enter the Path to your kubeconfig:"
}

# Check if the backup folder exists and contains helm_backup.7z
if (!(Test-Path $BackupPath)) {
    Write-Host "The backup folder $BackupPath does not exist."
    exit 1
}

if (!(Test-Path "$BackupPath\helm_backup.7z")) {
    Write-Host "The backup folder $BackupPath does not contain a helm_backup.7z file."
    exit 1
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
