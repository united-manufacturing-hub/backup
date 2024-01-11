param(
    [string]$IP, # IP of the cluster
    [string]$KubeconfigPath = "",
    [string]$OutputPath = "."
)

if (!$IP) {
    $KubeconfigPath = Read-Host -Prompt "Enter the IP of your server:"
}

if (!$KubeconfigPath) {
    $KubeconfigPath = Read-Host -Prompt "Enter the Path to your kubeconfig:"
}

$ArchiveName = "${OutputPath}/companion_backup.7z"
$Namespace = "mgmtcompanion"
$StatefulsetName = "mgmtcompanion"
$SecretName = "mgmtcompanion-secret"
$ConfigmapName = "mgmtcompanion-config"

if (Test-Path $ArchiveName) {
    $overwrite = Read-Host -Prompt "The file $ArchiveName already exists. Do you want to overwrite it? (y/N)"
    if ($overwrite.ToLower() -ne 'y') {
        Write-Host "Aborted. No changes have been made to the existing $ArchiveName."
        exit 1
    }
}

# Create directory for companion
New-Item -Path ".\companion" -ItemType Directory -Force | Out-Null

# Save statefulset

Write-Host "Saving $StatefulsetName.yaml to .\companion\$StatefulsetName.yaml"
.\_tools\kubectl.exe --kubeconfig $kubeconfigPath -n $Namespace get statefulset $StatefulsetName -o yaml > ".\companion\${StatefulsetName}.yaml"

# Save secret
Write-Host "Saving $SecretName.yaml to .\companion\$SecretName.yaml"
.\_tools\kubectl.exe --kubeconfig $kubeconfigPath -n $Namespace get secret $SecretName -o yaml > ".\companion\${SecretName}.yaml"

# Save config map
Write-Host "Saving $ConfigmapName.yaml to .\companion\$ConfigmapName.yaml"
.\_tools\kubectl.exe --kubeconfig $kubeconfigPath -n $Namespace get configmap $ConfigmapName -o yaml > ".\companion\${ConfigmapName}.yaml"

# Compress the nodered folder
$SevenZipPath = ".\_tools\7z.exe"
& $SevenZipPath a -m0=zstd -mx0 -md=16m -mmt=on -mfb=64 "${ArchiveName}" ".\companion\" | Out-Null

# Delete the companion folder
Remove-Item -Path ".\companion\" -Recurse -Force

Write-Host "Companion folder compressed to $ArchiveName and deleted"