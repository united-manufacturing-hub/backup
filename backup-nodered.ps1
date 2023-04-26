param(
    [string]$KubeconfigPath = "",
    [string]$OutputPath = "."
)

function SaveKubeFiles($kubeconfigPath, $namespace, $podName, $srcPath, $destPath) {
    .\_tools\kubectl.exe --kubeconfig $kubeconfigPath -n $namespace cp "${podName}:${srcPath}" $destPath
}

if (!$KubeconfigPath) {
    $KubeconfigPath = Read-Host -Prompt "Enter the Path to your kubeconfig:"
}

$ArchiveName = "${OutputPath}/nodered_backup.7z"
$Namespace = "united-manufacturing-hub"
$PodName = "united-manufacturing-hub-nodered-0"

if (Test-Path $ArchiveName) {
    $overwrite = Read-Host -Prompt "The file $ArchiveName already exists. Do you want to overwrite it? (y/N)"
    if ($overwrite.ToLower() -ne 'y') {
        Write-Host "Aborted. No changes have been made to the existing $ArchiveName."
        exit 1
    }
}

Write-Host "Saving hidden config files"
$HiddenConfigs = @(
    ".config.nodes.json",
    ".config.runtime.json",
    ".config.users.json",
    ".config.users.json.backup"
)

New-Item -Path "${OutputPath}/nodered" -ItemType Directory -Force | Out-Null

foreach ($config in $HiddenConfigs) {
    SaveKubeFiles -kubeconfigPath $KubeconfigPath -namespace $Namespace -podName $PodName -srcPath "/data/$config" -destPath "${OutputPath}/nodered/$config"
}

Write-Host "Saving settings, flows, and credentials"
$SettingsFiles = @{
    "settings.js"        = "settings.js";
    "flows.json"         = "flows.json";
    "flows_cred.json"    = "flows_cred.json"
}

foreach ($file in $SettingsFiles.Keys) {
    SaveKubeFiles -kubeconfigPath $KubeconfigPath -namespace $Namespace -podName $PodName -srcPath "/data/$file" -destPath "${OutputPath}/nodered/$($SettingsFiles[$file])"
}

Write-Host "Saving lib"
SaveKubeFiles -kubeconfigPath $KubeconfigPath -namespace $Namespace -podName $PodName -srcPath "/data/lib" -destPath "${OutputPath}/nodered/lib"

# Compress the nodered folder
$SevenZipPath = ".\_tools\7z.exe"
& $SevenZipPath a -m0=zstd -mx0 -md=16m -mmt=on -mfb=64 "${ArchiveName}" "${OutputPath}/nodered/" | Out-Null

# Delete the nodered folder
Remove-Item -Path "${OutputPath}/nodered" -Recurse -Force

Write-Host "Node-RED folder compressed to $ArchiveName and deleted"
