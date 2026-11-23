# Script: CopyFileFromRemoteShare.ps1
$username = "WIN01\john"
$password = "SuperSecurePass123"  
$securePassword = ConvertTo-SecureString $password -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)

$remoteShare = "\\FileServer01\SharedFolder"
$sourceFileName = Read-Host -Prompt "File> "
$sourceFile = "$remoteShare\$sourceFileName"
$destinationFile = "C:\Temp\$sourceFileName"
$destinationDir = "C:\Temp"

if (-not (Test-Path $destinationDir)) {
    New-Item -Path $destinationDir -ItemType Directory -Force
}

try {
    New-PSDrive -Name "Z" -PSProvider FileSystem -Root $remoteShare -Credential $credential -ErrorAction Stop

    if (Test-Path "Z:\$sourceFileName") {
        Copy-Item -Path "Z:\$sourceFileName" -Destination $destinationFile -Force
        Write-Output "File copied successfully to $destinationFile"
    } else {
        Write-Output "Error: File '$sourceFileName' not found in $remoteShare"
    }
} catch {
    Write-Output "An error occurred: $_"
} finally {
    Remove-PSDrive -Name "Z" -Force -ErrorAction SilentlyContinue
}