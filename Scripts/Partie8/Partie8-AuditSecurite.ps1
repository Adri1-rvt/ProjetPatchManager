<#
.SYNOPSIS
    Partie 8 - Audit de sécurité de la solution de Patch Management.
.DESCRIPTION
    Vérifie automatiquement la configuration de sécurité de l'administration distante :
      Sur chaque poste supervisé (via PowerShell Remoting) :
        - qui peut ouvrir une session distante (droits du point de terminaison PowerShell,
          membres des groupes Administrateurs et Utilisateurs de gestion à distance) ;
        - présence du point de terminaison JEA PatchManagement ;
        - écouteurs WinRM (HTTP / HTTPS) et méthodes d'authentification autorisées ;
        - mode d'authentification réellement utilisé par la session (NTLM ou Kerberos) ;
        - règles de pare-feu ouvrant le port WinRM et adresses autorisées ;
        - LocalAccountTokenFilterPolicy et journalisation PowerShell.
      Sur le poste d'administration :
        - liste TrustedHosts, chiffrement côté client ;
        - droits d'accès aux dossiers credentials et Rapports.
    Chaque constat reçoit un niveau (OK, INFO, ATTENTION, RISQUE) et une recommandation.
    Résultats : console + Rapports\SecurityAudit.csv + ligne dans le journal.
.EXAMPLE
    .\Partie8-AuditSecurite.ps1
#>
[CmdletBinding()]
param()

Import-Module (Join-Path $PSScriptRoot '..\Commun\PatchManager.psm1') -Force -ErrorAction Stop
$paths     = Get-ProjectPaths
$computers = Get-ComputerInventory -Path $paths.Inventory
$constats  = [System.Collections.Generic.List[object]]::new()

function Add-Constat {
    param($Cible, $Controle, $Constat, [ValidateSet('OK', 'INFO', 'ATTENTION', 'RISQUE')]$Niveau, $Recommandation = '')
    $constats.Add([PSCustomObject][ordered]@{
        Cible = $Cible; Controle = $Controle; Niveau = $Niveau; Constat = $Constat; Recommandation = $Recommandation
    })
}

# SID connus (indépendants de la langue de Windows)
$sidLarges = @{ 'S-1-1-0' = 'Tout le monde'; 'S-1-5-11' = 'Utilisateurs authentifiés'; 'S-1-5-32-545' = 'Utilisateurs' }

# =====================================================================
# 1. Contrôles sur chaque poste supervisé
# =====================================================================
$controleDistant = {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($id)

    $membres = {
        param($sid)
        try { @(Get-LocalGroupMember -SID $sid -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { @('(lecture impossible)') }
    }

    $regles = @(Get-NetFirewallPortFilter -Protocol TCP |
        Where-Object { $_.LocalPort -contains '5985' -or $_.LocalPort -contains '5986' } |
        Get-NetFirewallRule |
        Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' } |
        ForEach-Object {
            $adr = ($_ | Get-NetFirewallAddressFilter).RemoteAddress -join ','
            [PSCustomObject]@{ Nom = $_.DisplayName; Id = $_.Name; Profil = [string]$_.Profile; Adresses = $adr }
        })

    # La configuration WinRM n'est lisible que par un administrateur
    $ecouteurs = @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue | ForEach-Object {
        ($_.Keys | Where-Object { $_ -like 'Transport=*' }) -replace 'Transport=', ''
    })
    $auth = @{}
    Get-ChildItem WSMan:\localhost\Service\Auth -ErrorAction SilentlyContinue | ForEach-Object { $auth[$_.Name] = $_.Value }
    $nonChiffre = (Get-Item WSMan:\localhost\Service\AllowUnencrypted -ErrorAction SilentlyContinue).Value

    $latfp = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
    $sbl   = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -ErrorAction SilentlyContinue).EnableScriptBlockLogging
    $trans = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription' -ErrorAction SilentlyContinue).EnableTranscripting
    try   { $droits = (Get-PSSessionConfiguration -Name microsoft.powershell -ErrorAction Stop).Permission }
    catch { $droits = '(lecture réservée aux administrateurs)' }
    try   { $jea = (Get-PSSessionConfiguration -Name PatchManagement -ErrorAction Stop).Permission }
    catch { $jea = $null }
    $admins  = & $membres 'S-1-5-32-544'
    $gestion = & $membres 'S-1-5-32-580'

    [PSCustomObject]@{
        Compte            = $id.Name
        EstAdmin          = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        AuthSession       = $id.AuthenticationType
        DroitsEndpoint    = $droits
        Jea               = $jea
        Administrateurs   = $admins
        GestionDistance   = $gestion
        Ecouteurs         = $ecouteurs
        AuthBasic         = [string]$auth['Basic']
        AuthKerberos      = [string]$auth['Kerberos']
        AuthCredSSP       = [string]$auth['CredSSP']
        NonChiffre        = [string]$nonChiffre
        ReglesWinRM       = $regles
        LATFP             = $latfp
        ScriptBlockLog    = $sbl
        Transcription     = $trans
    }
}

foreach ($c in $computers) {
    Write-Host "  Contrôle de $($c.Name) ($($c.IP))..." -ForegroundColor Cyan
    $test = Test-ComputerAvailability -Computer $c
    if ($test.Etat -ne 'Accessible') {
        Add-Constat $c.Name 'Accessibilité' "Poste non contrôlé : $($test.Erreur)" 'INFO'
        continue
    }
    # Point 3 : privilèges du compte utilisé par les scripts de Patch Management
    $credPM = Get-StoredCredential -ComputerName $c.Name -CredentialFolder $paths.Credentials
    try {
        $pm = Invoke-Command -ComputerName $c.IP -Credential $credPM -ErrorAction Stop -ScriptBlock {
            $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            [PSCustomObject]@{
                Compte   = $id.Name
                EstAdmin = ([System.Security.Principal.WindowsPrincipal]::new($id)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
            }
        }
        if ($pm.EstAdmin) {
            Add-Constat $c.Name 'Compte du Patch Management' "$($pm.Compte) dispose des droits administrateur" 'ATTENTION' 'Utiliser un compte dédié non administrateur (Partie8-Durcissement.ps1)'
        } else {
            Add-Constat $c.Name 'Compte du Patch Management' "$($pm.Compte) n'est pas administrateur (moindre privilège)" 'OK'
        }
    }
    catch {
        Add-Constat $c.Name 'Compte du Patch Management' "Connexion impossible avec le compte du Patch Management : $($_.Exception.Message)" 'ATTENTION'
    }

    # Contrôles de configuration : avec le compte d'administration s'il est enregistré
    $credAudit = Get-StoredCredential -ComputerName $c.Name -CredentialFolder $paths.Credentials -Admin
    if (-not $credAudit) { $credAudit = $credPM }
    try {
        $r = Invoke-Command -ComputerName $c.IP -Credential $credAudit -ScriptBlock $controleDistant -ErrorAction Stop
    }
    catch {
        Add-Constat $c.Name 'Accessibilité' "Contrôle de configuration impossible : $($_.Exception.Message)" 'ATTENTION' 'Enregistrer le compte d''administration : Initialize-Credentials.ps1 -Admin'
        continue
    }
    if (-not $r.EstAdmin) {
        Add-Constat $c.Name 'Portée de l''audit' 'Contrôles réalisés sans droits administrateur : certains paramètres WinRM sont illisibles' 'INFO' 'Enregistrer le compte d''administration : Initialize-Credentials.ps1 -Admin'
    }

    # Point 2 : qui peut ouvrir une session distante
    Add-Constat $c.Name 'Droits du point de terminaison PowerShell' $r.DroitsEndpoint 'INFO'
    Add-Constat $c.Name 'Groupe Administrateurs' ($r.Administrateurs -join ', ') 'INFO' 'Limiter ce groupe aux comptes strictement nécessaires'
    $gd = if ($r.GestionDistance) { $r.GestionDistance -join ', ' } else { '(vide)' }
    Add-Constat $c.Name 'Groupe Utilisateurs de gestion à distance' $gd 'INFO'

    # Point 7 : point de terminaison JEA
    if ($r.EstAdmin) {
        if ($r.Jea) { Add-Constat $c.Name 'Point de terminaison JEA' "PatchManagement présent, accès : $($r.Jea)" 'OK' }
        else { Add-Constat $c.Name 'Point de terminaison JEA' 'Absent : le compte de service ne peut pas lire les correctifs' 'ATTENTION' 'Lancer Scripts\Partie8\Partie8-InstallJEA.ps1' }
    }

    # Point 6 : authentification
    $niveauAuth = if ($r.AuthSession -eq 'Kerberos') { 'OK' } else { 'INFO' }
    Add-Constat $c.Name 'Authentification de la session' "Mode utilisé : $($r.AuthSession)" $niveauAuth 'Kerberos est préférable dans un domaine Active Directory (authentification mutuelle, sans TrustedHosts)'
    if ($r.AuthBasic -eq 'true') { Add-Constat $c.Name 'Authentification Basic' 'Activée' 'RISQUE' 'Désactiver : Set-Item WSMan:\localhost\Service\Auth\Basic $false' }
    elseif ($r.AuthBasic -eq 'false') { Add-Constat $c.Name 'Authentification Basic' 'Désactivée' 'OK' }
    if ($r.AuthCredSSP -eq 'true') { Add-Constat $c.Name 'Authentification CredSSP' 'Activée (délégation des identifiants)' 'RISQUE' 'Désactiver CredSSP sauf besoin justifié' }
    if ($r.NonChiffre -eq 'true') { Add-Constat $c.Name 'Trafic non chiffré' 'AllowUnencrypted = true' 'RISQUE' 'Remettre AllowUnencrypted à false' }
    elseif ($r.NonChiffre -eq 'false') { Add-Constat $c.Name 'Trafic non chiffré' 'Refusé (AllowUnencrypted = false)' 'OK' }
    if ($r.Ecouteurs) {
        $niveauEcoute = if ($r.Ecouteurs -contains 'HTTPS') { 'OK' } else { 'INFO' }
        Add-Constat $c.Name 'Écouteurs WinRM' ($r.Ecouteurs -join ', ') $niveauEcoute 'Un écouteur HTTPS (port 5986, certificat) ajoute l''authentification du serveur hors domaine'
    }

    # Point 5 : pare-feu
    foreach ($regle in $r.ReglesWinRM) {
        $ouverte = ($regle.Adresses -eq 'Any') -or ($regle.Adresses -match 'LocalSubnet')
        if ($ouverte) {
            Add-Constat $c.Name 'Pare-feu WinRM' "Règle « $($regle.Nom) » ($($regle.Profil)) : autorise $($regle.Adresses)" 'RISQUE' "Désactiver cette règle : Disable-NetFirewallRule -Name '$($regle.Id)'"
        } else {
            Add-Constat $c.Name 'Pare-feu WinRM' "Règle « $($regle.Nom) » ($($regle.Profil)) : limitée à $($regle.Adresses)" 'OK'
        }
    }

    # Durcissements complémentaires
    if ($r.LATFP -eq 1) {
        Add-Constat $c.Name 'LocalAccountTokenFilterPolicy' '1 : les administrateurs locaux gardent leurs droits complets à distance' 'ATTENTION' 'Remettre à 0 une fois le compte dédié non administrateur en place'
    } else {
        Add-Constat $c.Name 'LocalAccountTokenFilterPolicy' 'Filtrage UAC actif pour les comptes locaux distants' 'OK'
    }
    if ($r.ScriptBlockLog -eq 1) { Add-Constat $c.Name 'Journalisation PowerShell' 'Script Block Logging activé' 'OK' }
    else { Add-Constat $c.Name 'Journalisation PowerShell' 'Script Block Logging désactivé : les commandes distantes laissent peu de traces' 'ATTENTION' 'Activer la stratégie « Activer la journalisation des blocs de scripts PowerShell »' }
}

# =====================================================================
# 2. Contrôles sur le poste d'administration
# =====================================================================
Write-Host "  Contrôle du poste d'administration ($env:COMPUTERNAME)..." -ForegroundColor Cyan
$admin = "$env:COMPUTERNAME (admin)"

try {
    $th = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
    if ($th -match '(^|,)\s*\*\s*(,|$)') { Add-Constat $admin 'TrustedHosts' "Valeur : $th" 'RISQUE' 'Lister uniquement les postes du parc' }
    elseif ($th) { Add-Constat $admin 'TrustedHosts' "Limité à : $th" 'OK' }
    else { Add-Constat $admin 'TrustedHosts' 'Vide' 'INFO' }

    $clientNonChiffre = (Get-Item WSMan:\localhost\Client\AllowUnencrypted -ErrorAction Stop).Value
    if ($clientNonChiffre -eq 'true') { Add-Constat $admin 'Client WinRM' 'AllowUnencrypted = true' 'RISQUE' 'Remettre à false' }
    else { Add-Constat $admin 'Client WinRM' 'Trafic non chiffré refusé' 'OK' }
}
catch {
    Add-Constat $admin 'Configuration WinRM' "Lecture impossible (service WinRM arrêté ?) : $($_.Exception.Message)" 'INFO'
}

# Point 4 : droits sur les fichiers produits
foreach ($dossier in @($paths.Credentials, $paths.Reports)) {
    if (-not (Test-Path $dossier)) { continue }
    $nom   = Split-Path $dossier -Leaf
    try   { $acces = (Get-Acl $dossier -ErrorAction Stop).Access | Where-Object AccessControlType -eq 'Allow' }
    catch { Add-Constat $admin "Droits sur $nom\" "Lecture des droits impossible : $($_.Exception.Message)" 'INFO'; continue }
    $larges = foreach ($a in $acces) {
        try { $sid = $a.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $sid = '' }
        if ($sidLarges.ContainsKey($sid)) { "$($a.IdentityReference) ($($a.FileSystemRights))" }
    }
    $titulaires = ($acces | ForEach-Object { $_.IdentityReference.Value } | Select-Object -Unique) -join ', '
    if ($larges) {
        Add-Constat $admin "Droits sur $nom\" "Accessible à des groupes larges : $($larges -join ' ; ')" 'RISQUE' 'Lancer Scripts\Partie8\Protect-ProjectFiles.ps1'
    } else {
        Add-Constat $admin "Droits sur $nom\" "Accès limité à : $titulaires" 'OK'
    }
}

# =====================================================================
# 3. Restitution
# =====================================================================
$couleurs = @{ OK = 'Green'; INFO = 'Gray'; ATTENTION = 'Yellow'; RISQUE = 'Red' }
foreach ($groupe in $constats | Group-Object Cible) {
    Write-Host "`n=== $($groupe.Name) ===" -ForegroundColor Cyan
    foreach ($k in $groupe.Group) {
        Write-Host ('  [{0,-9}] {1} : {2}' -f $k.Niveau, $k.Controle, $k.Constat) -ForegroundColor $couleurs[$k.Niveau]
        if ($k.Niveau -in 'ATTENTION', 'RISQUE' -and $k.Recommandation) {
            Write-Host "              -> $($k.Recommandation)" -ForegroundColor DarkGray
        }
    }
}

$nbRisques   = @($constats | Where-Object Niveau -eq 'RISQUE').Count
$nbAttention = @($constats | Where-Object Niveau -eq 'ATTENTION').Count
Write-Host "`nBilan : $nbRisques risque(s), $nbAttention point(s) d'attention." -ForegroundColor $(if ($nbRisques) { 'Red' } elseif ($nbAttention) { 'Yellow' } else { 'Green' })

$fichier = Export-ReportCsv -InputObject $constats -Path (Join-Path $paths.Reports 'SecurityAudit.csv')
Write-PatchLog "Audit de sécurité ; $nbRisques risque(s) ; $nbAttention point(s) d'attention"
Write-Host "Résultats enregistrés : $fichier" -ForegroundColor Cyan
