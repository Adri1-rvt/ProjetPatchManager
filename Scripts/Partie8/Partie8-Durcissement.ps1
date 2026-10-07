<#
.SYNOPSIS
    Partie 8 - Durcissement des postes supervisés.
.DESCRIPTION
    Applique à distance, sur chaque poste accessible, les mesures issues de l'audit de sécurité :
      1. Moindre privilège : crée (ou met à jour) un compte local dédié au Patch Management,
         NON administrateur, membre du seul groupe « Utilisateurs de gestion à distance ».
         Ce compte ne peut pas lire les correctifs installés : il les obtient par le point
         de terminaison JEA installé par Partie8-InstallJEA.ps1.
      2. Pare-feu : s'assure qu'une règle autorise WinRM depuis le seul poste d'administration,
         PUIS désactive les règles WinRM par défaut qui l'autorisent depuis n'importe quelle adresse.
      3. Traçabilité : active la journalisation des blocs de scripts PowerShell
         (journal Microsoft-Windows-PowerShell/Operational, événement 4104).
      4. (option -DisableLocalAdminRemote) remet LocalAccountTokenFilterPolicy à 0 : les comptes
         administrateurs locaux perdent leurs droits d'administration à distance.
    Les connexions utilisent le compte d'administration enregistré (credentials\<NOM>.admin.xml).
.PARAMETER ServiceAccount
    Nom du compte de service à créer (par défaut : svc_patch).
.PARAMETER AdminIP
    Adresse du poste d'administration autorisée à joindre WinRM (par défaut : 192.168.93.1).
.PARAMETER DisableLocalAdminRemote
    Retire les droits d'administration à distance aux comptes administrateurs locaux.
    À n'utiliser qu'une fois le compte de service validé : ensuite, toute administration
    des postes (dont ce script) se fait depuis leur console.
.EXAMPLE
    .\Partie8-Durcissement.ps1
.EXAMPLE
    .\Partie8-Durcissement.ps1 -DisableLocalAdminRemote
#>
[CmdletBinding()]
param(
    [string]$ServiceAccount = 'svc_patch',
    [string]$AdminIP = '192.168.93.1',
    [switch]$DisableLocalAdminRemote
)

Import-Module (Join-Path $PSScriptRoot '..\Commun\PatchManager.psm1') -Force -ErrorAction Stop
$paths     = Get-ProjectPaths
$computers = Get-ComputerInventory -Path $paths.Inventory

$svcCred = Get-Credential -UserName $ServiceAccount -Message "Mot de passe du compte de service $ServiceAccount (créé ou mis à jour sur chaque poste)"
if (-not $svcCred) { Write-Host 'Saisie annulée.' -ForegroundColor Yellow; return }

$durcissement = {
    param($User, [securestring]$Password, $AdminIP, $DisableLatfp)
    $actions = [System.Collections.Generic.List[string]]::new()

    # 1. Compte de service non administrateur
    if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) {
        Set-LocalUser -Name $User -Password $Password -PasswordNeverExpires $true
        $actions.Add("Compte $User existant : mot de passe mis à jour")
    }
    else {
        New-LocalUser -Name $User -Password $Password -PasswordNeverExpires -UserMayNotChangePassword `
            -Description 'Compte de service Patch Management' | Out-Null
        $actions.Add("Compte $User créé")
    }
    Add-LocalGroupMember -SID 'S-1-5-32-580' -Member $User -ErrorAction SilentlyContinue      # Utilisateurs de gestion à distance
    Remove-LocalGroupMember -SID 'S-1-5-32-544' -Member $User -ErrorAction SilentlyContinue   # Administrateurs
    $actions.Add("$User : membre de Utilisateurs de gestion à distance, absent du groupe Administrateurs")

    # 2. Pare-feu : d'abord garantir l'accès du poste d'administration, ensuite fermer le reste
    $regleAdmin = Get-NetFirewallPortFilter -Protocol TCP | Where-Object { $_.LocalPort -contains '5985' } |
        Get-NetFirewallRule | Where-Object {
            $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' -and
            (($_ | Get-NetFirewallAddressFilter).RemoteAddress -contains $AdminIP)
        } | Select-Object -First 1
    if (-not $regleAdmin) {
        New-NetFirewallRule -DisplayName 'WinRM - Poste admin uniquement' -Direction Inbound -Protocol TCP `
            -LocalPort 5985 -RemoteAddress $AdminIP -Action Allow -Profile Any | Out-Null
        $actions.Add("Règle créée : WinRM autorisé depuis $AdminIP uniquement")
    }
    $defaut = @(Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue | Where-Object Enabled -eq 'True')
    foreach ($r in $defaut) {
        Disable-NetFirewallRule -Name $r.Name
        $actions.Add("Règle par défaut désactivée : $($r.DisplayName) [$($r.Name)]")
    }

    # 3. Journalisation des blocs de scripts PowerShell
    $cle = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'
    if (-not (Test-Path $cle)) { New-Item -Path $cle -Force | Out-Null }
    Set-ItemProperty -Path $cle -Name EnableScriptBlockLogging -Value 1 -Type DWord
    $actions.Add('Script Block Logging activé (événement 4104)')

    # 4. Option : plus d'administration à distance avec un compte administrateur local
    if ($DisableLatfp) {
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
            -Name LocalAccountTokenFilterPolicy -Value 0 -Type DWord
        $actions.Add('LocalAccountTokenFilterPolicy = 0 : administrateurs locaux sans droits complets à distance')
    }

    $actions
}

foreach ($c in $computers) {
    Write-Host "`n=== $($c.Name) ($($c.IP)) ===" -ForegroundColor Cyan
    $test = Test-ComputerAvailability -Computer $c
    if ($test.Etat -ne 'Accessible') {
        Write-Host "  Ignoré : $($test.Erreur)" -ForegroundColor Yellow
        continue
    }
    $credAdmin = Get-StoredCredential -ComputerName $c.Name -CredentialFolder $paths.Credentials -Admin
    if (-not $credAdmin) {
        Write-Host '  Ignoré : identifiants d''administration absents (Initialize-Credentials.ps1 -Admin)' -ForegroundColor Red
        continue
    }
    try {
        $actions = Invoke-Command -ComputerName $c.IP -Credential $credAdmin -ErrorAction Stop `
            -ScriptBlock $durcissement -ArgumentList $ServiceAccount, $svcCred.Password, $AdminIP, $DisableLocalAdminRemote.IsPresent
        foreach ($a in $actions) { Write-Host "  - $a" -ForegroundColor Green }
        Write-PatchLog "$($c.Name) ; Durcissement appliqué ; $($actions.Count) action(s)"
    }
    catch {
        Write-Host "  Échec : $($_.Exception.Message)" -ForegroundColor Red
        Write-PatchLog "$($c.Name) ; ERREUR ; Durcissement non appliqué ; $($_.Exception.Message)"
    }
}

Write-Host "`nÉtape suivante : enregistrer le compte de service pour les scripts du projet :" -ForegroundColor Cyan
Write-Host "  .\Scripts\Commun\Initialize-Credentials.ps1 -UserName $ServiceAccount"
