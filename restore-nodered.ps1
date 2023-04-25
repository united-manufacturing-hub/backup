param(
    [string]$KubeconfigPath = "",
    [string]$BackupPath = ""
)

function KubectlCopyToServer($kubeconfigPath, $namespace, $srcPath, $podName, $destPath) {
    # Ignore errors here
    .\_tools\kubectl.exe --kubeconfig $kubeconfigPath -n $namespace cp $srcPath "${podName}:${destPath}" | Out-Null
}

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

if (!(Test-Path "$BackupPath\nodered_backup.7z")) {
    Write-Host "The backup folder $BackupPath does not contain a nodered_backup.7z file."
    exit 1
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
