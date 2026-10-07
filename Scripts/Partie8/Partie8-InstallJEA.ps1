<#
.SYNOPSIS
    Partie 8 - Installation d'un point de terminaison JEA (Just Enough Administration).
.DESCRIPTION
    Installe sur chaque poste un point de terminaison PowerShell restreint, « PatchManagement » :
      - seul le compte de service (svc_patch) peut s'y connecter ;
      - il n'y voit qu'UNE commande : Get-PatchAuditData (collecte en lecture seule) ;
      - le langage PowerShell y est désactivé (NoLanguage) : pas de variables, de scripts
        ni d'appels .NET, seulement la commande autorisée ;
      - les commandes s'exécutent sous un compte virtuel temporaire, administrateur local,
        créé pour la durée de la session : le compte de service, lui, reste non administrateur ;
      - chaque session est enregistrée (transcription) dans C:\ProgramData\JEA\Transcripts ;
      - la stratégie d'exécution RemoteSigned ne s'applique qu'à ce point de terminaison
        (nécessaire pour charger le module JEA ; la stratégie du poste reste inchangée).
    Le code de Get-PatchAuditData est celui du module PatchManager.psm1 (Get-PatchAuditScript) :
    la collecte est identique, que le poste soit audité par JEA ou non.
    Le droit de lecture WMI à distance accordé auparavant au groupe « Utilisateurs de gestion
    à distance » devient inutile : il est retiré.
    Les connexions utilisent le compte d'administration enregistré (credentials\<NOM>.admin.xml).
.PARAMETER ServiceAccount
    Compte autorisé sur le point de terminaison (par défaut : svc_patch).
.EXAMPLE
    .\Partie8-InstallJEA.ps1
#>
[CmdletBinding()]
param(
    [string]$ServiceAccount = 'svc_patch'
)

Import-Module (Join-Path $PSScriptRoot '..\Commun\PatchManager.psm1') -Force -ErrorAction Stop
$paths     = Get-ProjectPaths
$computers = Get-ComputerInventory -Path $paths.Inventory
$codeAudit = Get-PatchAuditScript
$nomEndpoint = 'PatchManagement'

$installation = {
    param($User, $CodeAudit, $NomEndpoint)
    $actions = [System.Collections.Generic.List[string]]::new()

    # 1. Module JEA : la fonction autorisée et sa capacité de rôle
    $base = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\PatchManagementJEA'
    New-Item -ItemType Directory -Path (Join-Path $base 'RoleCapabilities') -Force | Out-Null
    # Une session JEA ne charge pas automatiquement les modules. Management et Utility y sont déjà ;
    # seul CimCmdlets (Get-CimInstance) manque : il est importé une seule fois, ici.
    $psm1 = "Import-Module CimCmdlets`r`n`r`n" +
            "function Get-PatchAuditData {`r`n$CodeAudit`r`n}`r`nExport-ModuleMember -Function Get-PatchAuditData"
    Set-Content -Path (Join-Path $base 'PatchManagementJEA.psm1') -Value $psm1 -Encoding UTF8
    New-ModuleManifest -Path (Join-Path $base 'PatchManagementJEA.psd1') -RootModule 'PatchManagementJEA.psm1' `
        -FunctionsToExport 'Get-PatchAuditData' -Description 'Collecte en lecture seule pour le Patch Management'
    New-PSRoleCapabilityFile -Path (Join-Path $base 'RoleCapabilities\PatchAudit.psrc') `
        -ModulesToImport 'PatchManagementJEA' `
        -VisibleFunctions 'Get-PatchAuditData' `
        -Description 'Lecture de l''inventaire et des correctifs uniquement'
    $actions.Add('Module PatchManagementJEA installé (une seule fonction visible : Get-PatchAuditData)')

    # 2. Retrait du droit WMI à distance devenu inutile (ajouté par une version précédente du durcissement)
    $security  = Get-WmiObject -Namespace 'root\cimv2' -Class __SystemSecurity
    $binarySD  = @($null)
    [void]$security.PsBase.InvokeMethod('GetSD', $binarySD)
    $converter = New-Object System.Management.ManagementClass Win32_SecurityDescriptorHelper
    $sddl      = $converter.BinarySDToSDDL($binarySD[0]).SDDL
    $nettoye   = $sddl -replace '\(A;CI;CCWP;;;(RM|S-1-5-32-580)\)', ''
    if ($nettoye -ne $sddl) {
        $binarySD[0] = $converter.SDDLToBinarySD($nettoye).BinarySD
        [void]$security.PsBase.InvokeMethod('SetSD', $binarySD)
        $actions.Add('Droit WMI à distance retiré au groupe Utilisateurs de gestion à distance')
    }

    # 3. Configuration du point de terminaison
    $dossierJea = Join-Path $env:ProgramData 'JEA'
    New-Item -ItemType Directory -Path (Join-Path $dossierJea 'Transcripts') -Force | Out-Null
    $pssc = Join-Path $dossierJea "$NomEndpoint.pssc"
    # ExecutionPolicy : la stratégie par défaut de Windows client (Restricted) empêcherait le chargement
    # du module JEA. RemoteSigned ne s'applique qu'aux sessions de ce point de terminaison.
    New-PSSessionConfigurationFile -Path $pssc -SessionType RestrictedRemoteServer -RunAsVirtualAccount `
        -ExecutionPolicy RemoteSigned `
        -TranscriptDirectory (Join-Path $dossierJea 'Transcripts') `
        -RoleDefinitions @{ "$env:COMPUTERNAME\$User" = @{ RoleCapabilities = 'PatchAudit' } }
    if (-not (Test-PSSessionConfigurationFile -Path $pssc)) { throw "Fichier de configuration JEA invalide : $pssc" }
    $actions.Add("Configuration créée : $pssc (compte virtuel, transcription, accès réservé à $User)")

    # 4. Enregistrement : WinRM redémarre, ce qui coupe la session en cours
    if (Get-PSSessionConfiguration -Name $NomEndpoint -ErrorAction SilentlyContinue) {
        Unregister-PSSessionConfiguration -Name $NomEndpoint -NoServiceRestart
    }
    $actions.Add("Enregistrement du point de terminaison $NomEndpoint (redémarrage de WinRM)")
    $actions
    Register-PSSessionConfiguration -Name $NomEndpoint -Path $pssc -Force | Out-Null
}

foreach ($c in $computers) {
    Write-Host "`n=== $($c.Name) ($($c.IP)) ===" -ForegroundColor Cyan
    $test = Test-ComputerAvailability -Computer $c
    if ($test.Etat -ne 'Accessible') { Write-Host "  Ignoré : $($test.Erreur)" -ForegroundColor Yellow; continue }

    $credAdmin = Get-StoredCredential -ComputerName $c.Name -CredentialFolder $paths.Credentials -Admin
    if (-not $credAdmin) { Write-Host '  Ignoré : identifiants d''administration absents (Initialize-Credentials.ps1 -Admin)' -ForegroundColor Red; continue }

    # L'enregistrement redémarre WinRM : la coupure de la session est normale, on vérifie ensuite
    try {
        $actions = Invoke-Command -ComputerName $c.IP -Credential $credAdmin -ErrorAction Stop `
            -ScriptBlock $installation -ArgumentList $ServiceAccount, $codeAudit, $nomEndpoint
        foreach ($a in $actions) { Write-Host "  - $a" -ForegroundColor Green }
    }
    catch {
        Write-Host '  - Session interrompue par le redémarrage de WinRM (attendu), vérification...' -ForegroundColor DarkGray
    }

    Start-Sleep -Seconds 5
    $credSvc = Get-StoredCredential -ComputerName $c.Name -CredentialFolder $paths.Credentials
    try {
        $verif = Invoke-PatchAudit -Computer $c -Credential $credSvc -ConfigurationName $nomEndpoint
        if ($verif.Endpoint -ne $nomEndpoint) { throw "le point de terminaison $nomEndpoint n'a pas été utilisé" }
        Write-Host "  Vérification : $ServiceAccount obtient $($verif.Correctifs.Count) correctif(s) via JEA, exécuté sous « $($verif.CompteExecution) »" -ForegroundColor Green
        Write-PatchLog "$($c.Name) ; Point de terminaison JEA $nomEndpoint installé et vérifié"
    }
    catch {
        Write-Host "  Vérification échouée : $($_.Exception.Message)" -ForegroundColor Red
        Write-PatchLog "$($c.Name) ; ERREUR ; Point de terminaison JEA non vérifié ; $($_.Exception.Message)"
    }
}
