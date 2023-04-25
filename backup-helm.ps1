param(
    [string]$KubeconfigPath = ""
)

function GetHelmValues($kubeconfigPath, $namespace, $releaseName, $outputFile) {
    .\_tools\helm.exe --kubeconfig $kubeconfigPath get values -n $namespace $releaseName --output yaml | Out-File $outputFile
}

if (!$KubeconfigPath) {
    $KubeconfigPath = Read-Host -Prompt "Enter the Path to your kubeconfig:"
}

$ArchiveName = "helm_backup.7z"
$Namespace = "united-manufacturing-hub"
$ReleaseName = "united-manufacturing-hub"

if (Test-Path $ArchiveName) {
    $overwrite = Read-Host -Prompt "The file $ArchiveName already exists. Do you want to overwrite it? (y/N)"
    if ($overwrite.ToLower() -ne 'y') {
        Write-Host "Aborted. No changes have been made to the existing $ArchiveName."
        exit 1
    }
}

New-Item -Path "./helm" -ItemType Directory -Force | Out-Null

Write-Host "Saving Helm values"
GetHelmValues -kubeconfigPath $KubeconfigPath -namespace $Namespace -releaseName $ReleaseName -outputFile "./helm/values.yaml"

# Compress the helm folder
$SevenZipPath = ".\_tools\7z.exe"
& $SevenZipPath a -m0=zstd -mx0 -md=16m -mmt=on -mfb=64 "${ArchiveName}" "./helm/"


# Delete the helm folder
Remove-Item -Path "./helm" -Recurse -Force

Write-Host "Helm folder compressed to $ArchiveName and deleted"
