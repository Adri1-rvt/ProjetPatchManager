<#
.SYNOPSIS
    Démonstration guidée du projet, pour l'enregistrement de la vidéo (environ 15 minutes).
.DESCRIPTION
    Enchaîne les démonstrations dans l'ordre du plan de la vidéo, en 10 sections.
    Avant chaque étape, la commande lancée s'affiche en jaune, puis le script attend [Entrée] :
    il n'y a rien à taper pendant l'enregistrement. Un chronomètre indique le temps écoulé
    et l'objectif de début de chaque section.

    Une vérification préalable (postes, identifiants, JEA, politique, messagerie) a lieu avant
    le démarrage du chronomètre ; elle sert aussi à « réveiller » WinRM sur les postes.

    La politique de correctifs est modifiée pendant la démonstration (ajout de KB5054156,
    sections 6 à 8). Elle est toujours restaurée à l'identique à la fin, y compris en cas
    d'erreur ou d'interruption par Ctrl+C.
.PARAMETER Section
    Section de départ (1 à 10), pour refaire une prise sans tout rejouer.
.PARAMETER DryRunMail
    Construit la notification de la section 8 sans l'envoyer (répétitions).
.PARAMETER AuditAvant
    Chemin de la capture de l'audit de sécurité « avant » durcissement, ouverte en section 9.
.PARAMETER NomA
    Présentateur des sections impaires (par défaut : Adrien).
.PARAMETER NomB
    Présentateur des sections paires (par défaut : Alexandre).
.PARAMETER NoPause
    Enchaîne tout sans attendre (répétition rapide, vérification que tout fonctionne).
.PARAMETER NoClear
    N'efface pas l'écran entre les sections.
.PARAMETER SkipChecks
    Saute la vérification préalable.
.EXAMPLE
    .\Scripts\Demo\Demo.ps1 -AuditAvant .\Screenshots\Partie8\audit-avant.png
.EXAMPLE
    .\Scripts\Demo\Demo.ps1 -Section 6 -DryRunMail
.EXAMPLE
    .\Scripts\Demo\Demo.ps1 -NoPause -DryRunMail      # répétition complète, sans pause
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 10)][int]$Section = 1,
    [switch]$DryRunMail,
    [string]$AuditAvant,
    [string]$NomA = 'Adrien',
    [string]$NomB = 'Alexandre',
    [string]$RepoUrl = 'https://github.com/Adri1-rvt/ProjetPatchManager',
    [switch]$NoPause,
    [switch]$NoClear,
    [switch]$SkipChecks
)

Import-Module (Join-Path $PSScriptRoot '..\Commun\PatchManager.psm1') -Force -ErrorAction Stop
$paths = Get-ProjectPaths

$kbDemo      = 'KB5054156'
$ligneKbDemo = "$kbDemo   # Nouveau correctif obligatoire (simulation)"
$politique   = $paths.RequiredPatches
$sauvegarde  = $null          # contenu exact de la politique avant modification
$chrono      = $null
if ($AuditAvant) { $AuditAvant = (Resolve-Path $AuditAvant -ErrorAction SilentlyContinue).Path }

# =====================================================================
# Outils d'affichage
# =====================================================================
function Wait-Demo([string]$Message = 'Entrée : continuer') {
    if ($NoPause) { return }
    Write-Host "`n  [$Message]" -ForegroundColor DarkGray -NoNewline
    [void](Read-Host)
}

function Show-Banner($s) {
    if (-not $NoClear) { Clear-Host }
    $ecoule = if ($chrono) { '{0:mm\:ss}' -f $chrono.Elapsed } else { '--:--' }
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host ("  {0}/10  {1}" -f $s.Num, $s.Titre) -ForegroundColor Cyan
    Write-Host ("        {0}" -f $s.SousTitre) -ForegroundColor Gray
    Write-Host ("        Présentation : {0}   |   Objectif : {1}   |   Écoulé : {2}" -f $s.Qui, $s.Debut, $ecoule) -ForegroundColor DarkGray
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

function Invoke-Step {
    # Affiche la commande, attend [Entrée], l'exécute ; une erreur n'interrompt jamais la démonstration
    param([string]$Commande, [scriptblock]$Action)
    Write-Host "`nPS> $Commande" -ForegroundColor Yellow
    Wait-Demo 'Entrée : lancer'
    try { & $Action }
    catch { Write-Host "Erreur : $($_.Exception.Message)" -ForegroundColor Red }
}

function Write-Note([string]$Texte) { Write-Host "`n  $Texte" -ForegroundColor Gray }

# =====================================================================
# Politique de correctifs : modification temporaire et restauration
# =====================================================================
function Add-KbDemo {
    if (Select-String -Path $politique -Pattern $kbDemo -Quiet) { return }
    if (-not $script:sauvegarde) { $script:sauvegarde = [System.IO.File]::ReadAllBytes($politique) }
    Add-Content -Path $politique -Value "`r`n$ligneKbDemo" -Encoding UTF8
}

function Restore-Politique {
    if ($script:sauvegarde) {
        [System.IO.File]::WriteAllBytes($politique, $script:sauvegarde)
        $script:sauvegarde = $null
        return $true
    }
    $false
}

# =====================================================================
# Postes et identifiants utilisés par la démonstration
# =====================================================================
$computers = @(Get-ComputerInventory -Path $paths.Inventory)
$pcA       = $computers | Select-Object -First 1
$svcA      = Get-StoredCredential -ComputerName $pcA.Name -CredentialFolder $paths.Credentials
$adminA    = Get-StoredCredential -ComputerName $pcA.Name -CredentialFolder $paths.Credentials -Admin

# =====================================================================
# Les 10 sections
# =====================================================================
$sections = @(
    @{ Num = 1; Qui = $NomA; Debut = '00:00'; Titre = 'Introduction'
       SousTitre = 'Le Patch Management et la chaîne : inventaire, conformité, rapport, alerte'
       Action = {
           Write-Note 'Chaîne de la solution :'
           Write-Host '    computers.txt  ->  PowerShell Remoting  ->  inventaire des correctifs' -ForegroundColor White
           Write-Host '    ->  contrôle de conformité  ->  rapport CSV / HTML + journal  ->  notification' -ForegroundColor White
           Write-Note '(Montrer le schéma d''architecture du rapport.)'
       } },

    @{ Num = 2; Qui = $NomB; Debut = '01:00'; Titre = 'Environnement et organisation du projet'
       SousTitre = 'Poste d''administration, 2 VM Windows 11, réseau host-only, module commun'
       Action = {
           Invoke-Step 'Get-ChildItem Config, Scripts -Recurse -File' {
               Get-ChildItem (Join-Path $paths.Root 'Config'), (Join-Path $paths.Root 'Scripts') -Recurse -File | Sort-Object FullName |
                   ForEach-Object { '  ' + $_.FullName.Substring($paths.Root.Length + 1) } | Write-Host
           }
           Invoke-Step 'Get-Content Config\computers.txt' { Get-Content $paths.Inventory | Write-Host }
           Invoke-Step "Get-Content credentials\$($pcA.Name).xml -TotalCount 12" {
               Get-Content (Join-Path $paths.Credentials "$($pcA.Name).xml") -TotalCount 12 | Write-Host
               Write-Note 'Mot de passe chiffré par DPAPI : lisible seulement par ce compte Windows, sur ce poste.'
           }
       } },

    @{ Num = 3; Qui = $NomA; Debut = '02:30'; Titre = 'Partie 1 - Disponibilité et PowerShell Remoting'
       SousTitre = 'Ping, WinRM, exécution de commandes à distance'
       Action = {
           Invoke-Step '.\Scripts\Partie1\Partie1-Disponibilite.ps1' {
               $null = & (Join-Path $paths.Root 'Scripts\Partie1\Partie1-Disponibilite.ps1')
           }
           Invoke-Step "Test-WSMan $($pcA.IP)" { Test-WSMan $pcA.IP | Out-Host }
           Invoke-Step "Invoke-Command -ComputerName $($pcA.IP) -Credential `$svc { hostname; whoami }" {
               Invoke-Command -ComputerName $pcA.IP -Credential $svcA -ScriptBlock { hostname; whoami } | Write-Host
               Write-Note "Les commandes s'exécutent sur $($pcA.Name), lancées depuis $env:COMPUTERNAME."
           }
       } },

    @{ Num = 4; Qui = $NomB; Debut = '04:00'; Titre = 'Partie 2 - Inventaire du parc'
       SousTitre = 'Matériel, version de Windows, disque, Windows Update, export CSV'
       Action = {
           Invoke-Step '.\Scripts\Partie2\Partie2-Inventaire.ps1' {
               & (Join-Path $paths.Root 'Scripts\Partie2\Partie2-Inventaire.ps1')
           }
           Invoke-Step 'Invoke-Item Rapports\Inventaire.csv' {
               Invoke-Item (Join-Path $paths.Reports 'Inventaire.csv')
               Write-Note 'Fermer Excel avant la section suivante.'
           }
       } },

    @{ Num = 5; Qui = $NomA; Debut = '05:15'; Titre = 'Partie 3 - Inventaire des correctifs'
       SousTitre = 'Correctifs de chaque poste, triés par poste puis par date'
       Action = {
           Invoke-Step '.\Scripts\Partie3\Partie3-Correctifs.ps1 -SkipLocal' {
               & (Join-Path $paths.Root 'Scripts\Partie3\Partie3-Correctifs.ps1') -SkipLocal
           }
       } },

    @{ Num = 6; Qui = $NomB; Debut = '06:30'; Titre = 'Partie 4 - Contrôle de conformité'
       SousTitre = 'Politique de correctifs, puis publication d''un nouveau correctif obligatoire'
       Action = {
           Invoke-Step '.\Scripts\Partie4\Partie4-Conformite.ps1' {
               & (Join-Path $paths.Root 'Scripts\Partie4\Partie4-Conformite.ps1')
           }
           Write-Note "Simulation : Microsoft publie un correctif, l'administrateur l'ajoute à la politique."
           Invoke-Step "Add-Content Config\required-patches.txt '$kbDemo'" {
               Add-KbDemo
               Get-Content $politique | Write-Host
           }
           Invoke-Step '.\Scripts\Partie4\Partie4-Conformite.ps1' {
               & (Join-Path $paths.Root 'Scripts\Partie4\Partie4-Conformite.ps1')
           }
       } },

    @{ Num = 7; Qui = $NomA; Debut = '08:15'; Titre = 'Partie 6 - Rapport de sécurité'
       SousTitre = 'Audit complet, synthèse, postes à traiter, rapport HTML, historique, journal'
       Action = {
           Invoke-Step '.\Scripts\Partie6\Partie6-RapportSecurite.ps1' {
               & (Join-Path $paths.Root 'Scripts\Partie6\Partie6-RapportSecurite.ps1')
           }
           Invoke-Step 'Invoke-Item Rapports\SecurityReport.html' {
               Invoke-Item (Join-Path $paths.Reports 'SecurityReport.html')
           }
           Invoke-Step 'Get-Content Rapports\PatchManager.log -Tail 10' {
               Get-Content $paths.Log -Tail 10 -Encoding UTF8 | Write-Host
           }
           Invoke-Step 'Get-ChildItem Rapports\Historique | Select-Object -Last 3' {
               Get-ChildItem (Join-Path $paths.Reports 'Historique') | Sort-Object LastWriteTime |
                   Select-Object -Last 3 Name, LastWriteTime | Out-Host
           }
       } },

    @{ Num = 8; Qui = $NomB; Debut = '10:15'; Titre = 'Partie 7 - Notification'
       SousTitre = 'E-mail envoyé uniquement en cas d''anomalie, rapport en pièces jointes'
       Action = {
           $option = if ($DryRunMail) { ' -DryRun' } else { '' }
           Invoke-Step ".\Scripts\Partie7\Partie7-Notification.ps1$option" {
               $script7 = Join-Path $paths.Root 'Scripts\Partie7\Partie7-Notification.ps1'
               if ($DryRunMail) { & $script7 -DryRun } else { & $script7 }
               if (-not $DryRunMail) { Write-Note 'Ouvrir la boîte de réception : le message et ses pièces jointes.' }
           }
           Invoke-Step 'Get-Content Rapports\PatchManager.log -Tail 2' {
               Get-Content $paths.Log -Tail 2 -Encoding UTF8 | Write-Host
           }
           Invoke-Step 'Restauration de la politique de correctifs' {
               if (Restore-Politique) { Write-Host '  Politique restaurée :' -ForegroundColor Green }
               Get-Content $politique | Write-Host
           }
       } },

    @{ Num = 9; Qui = "$NomA et $NomB"; Debut = '11:45'; Titre = 'Partie 8 - Sécurisation'
       SousTitre = 'Audit avant / après, compte de service non administrateur, JEA'
       Action = {
           if ($AuditAvant) {
               Invoke-Step 'Audit AVANT durcissement (capture)' { Invoke-Item $AuditAvant }
           }
           else {
               Write-Note 'Montrer la capture de l''audit AVANT durcissement (2 risques, 6 points d''attention).'
           }
           Invoke-Step '.\Scripts\Partie8\Partie8-AuditSecurite.ps1' {
               & (Join-Path $paths.Root 'Scripts\Partie8\Partie8-AuditSecurite.ps1')
           }

           Write-Note "JEA : svc_patch n'est pas administrateur et ne voit qu'une commande métier."
           Invoke-Step "Invoke-Command -ComputerName $($pcA.IP) -Credential `$svc -ConfigurationName PatchManagement { Get-Command }" {
               Invoke-Command -ComputerName $pcA.IP -Credential $svcA -ConfigurationName PatchManagement -ScriptBlock { Get-Command } |
                   Select-Object Name | Out-Host
           }
           Invoke-Step "Invoke-Command ... -ConfigurationName PatchManagement { Get-PatchAuditData }" {
               Invoke-Command -ComputerName $pcA.IP -Credential $svcA -ConfigurationName PatchManagement -ScriptBlock { Get-PatchAuditData } |
                   Select-Object NomMachine, Windows, CompteExecution | Format-List | Out-Host
               Write-Note 'La collecte tourne sous un compte virtuel temporaire, créé pour cette seule session.'
           }
           Invoke-Step "Invoke-Command ... -ConfigurationName PatchManagement { Stop-Service wuauserv }" {
               try {
                   Invoke-Command -ComputerName $pcA.IP -Credential $svcA -ConfigurationName PatchManagement `
                       -ScriptBlock { Stop-Service wuauserv } -ErrorAction Stop
                   Write-Host '  La commande a été acceptée : JEA n''est pas restreint comme prévu !' -ForegroundColor Red
               }
               catch {
                   Write-Host "  REFUSÉ : $($_.Exception.Message)" -ForegroundColor Red
               }
           }
           Invoke-Step "Dernière transcription JEA sur $($pcA.Name) (C:\ProgramData\JEA\Transcripts)" {
               Invoke-Command -ComputerName $pcA.IP -Credential $adminA -ScriptBlock {
                   Get-ChildItem C:\ProgramData\JEA\Transcripts -Recurse -File |
                       Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -TotalCount 25
               } | Write-Host
           }
       } },

    @{ Num = 10; Qui = "$NomA ou $NomB"; Debut = '14:15'; Titre = 'Conclusion'
       SousTitre = 'Bilan, limites, pistes d''évolution'
       Action = {
           Write-Note 'Limites : NTLM hors domaine, Send-MailMessage obsolète, contrôle par numéros de KB.'
           Write-Note 'Évolutions : domaine et Kerberos, WSUS ou Intune, Microsoft Graph, tâche planifiée.'
           if (Get-Command git -ErrorAction SilentlyContinue) {
               Invoke-Step 'git log --oneline -n 12' {
                   Push-Location $paths.Root
                   try { git log --oneline -n 12 | Write-Host } finally { Pop-Location }
               }
           }
           Write-Host "`n  Dépôt : $RepoUrl" -ForegroundColor Cyan
       } }
)

# =====================================================================
# Exécution
# =====================================================================
try {
    # ---------- Vérification préalable (avant le chronomètre) ----------
    if (-not $SkipChecks) {
        if (-not $NoClear) { Clear-Host }
        Write-Host 'Vérification préalable (hors enregistrement)' -ForegroundColor Cyan
        $alertes = 0
        $ok    = { param($t) Write-Host "  [OK] $t" -ForegroundColor Green }
        $alert = { param($t) Write-Host "  [!!] $t" -ForegroundColor Red; $script:alertes++ }
        $info  = { param($t) Write-Host "  [i]  $t" -ForegroundColor Gray }

        foreach ($c in $computers) {
            $t = Test-ComputerAvailability -Computer $c
            if ($t.Etat -eq 'Accessible') {
                & $ok "$($c.Name) accessible"
                if (-not (Get-StoredCredential -ComputerName $c.Name -CredentialFolder $paths.Credentials)) { & $alert "$($c.Name) : identifiants svc_patch absents" }
                if (-not (Get-StoredCredential -ComputerName $c.Name -CredentialFolder $paths.Credentials -Admin)) { & $alert "$($c.Name) : identifiants admin absents" }
            }
            else { & $info "$($c.Name) inaccessible ($($t.Erreur)) : attendu pour le poste fictif" }
        }

        if ($svcA) {
            try {
                $audit = Invoke-PatchAudit -Computer $pcA -Credential $svcA
                if ($audit.Endpoint -eq 'PatchManagement') { & $ok "JEA opérationnel sur $($pcA.Name) ($($audit.Correctifs.Count) correctifs)" }
                else { & $alert "JEA non utilisé sur $($pcA.Name) : relancer Partie8-InstallJEA.ps1" }
            }
            catch { & $alert "Collecte impossible sur $($pcA.Name) : $($_.Exception.Message)" }
        }

        $kbs = @(Get-RequiredPatches -Path $politique)
        if ($kbs -contains $kbDemo) { & $alert "La politique contient déjà $kbDemo : retirez-le pour que la section 6 commence à 100 %" }
        else { & $ok "Politique de correctifs : $($kbs.Count) KB ($($kbs -join ', '))" }

        if ($DryRunMail) { & $info 'Notification en mode test (-DryRunMail) : aucun e-mail envoyé' }
        elseif ((Test-Path $paths.MailConfig) -and (Test-Path $paths.MailCredential)) { & $ok 'Messagerie configurée : ouvrez la boîte de réception à l''avance' }
        else { & $alert 'Messagerie non configurée : utilisez -DryRunMail' }

        if ($AuditAvant) { & $ok "Capture de l'audit avant : $AuditAvant" }
        else { & $info 'Pas de capture -AuditAvant : vous la montrerez vous-même en section 9' }

        if (Get-Process EXCEL -ErrorAction SilentlyContinue) { & $alert 'Excel est ouvert : fermez-le (fichiers CSV verrouillés)' }

        $bilan = if ($alertes) { "$alertes point(s) à corriger avant d'enregistrer." } else { 'Tout est prêt.' }
        Write-Host "`n  $bilan" -ForegroundColor $(if ($alertes) { 'Red' } else { 'Green' })
        Wait-Demo 'Entrée : démarrer la démonstration (le chronomètre démarre)'
    }

    # Une prise reprise en section 7 ou 8 doit partir de la politique modifiée
    if ($Section -in 7, 8) { Add-KbDemo }

    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($s in $sections | Where-Object { $_.Num -ge $Section }) {
        Show-Banner $s
        & $s.Action
        if ($s.Num -lt 10) { Wait-Demo 'Entrée : section suivante' }
    }

    $chrono.Stop()
    Write-Host ("`n  Fin de la démonstration - durée : {0:mm\:ss}" -f $chrono.Elapsed) -ForegroundColor Cyan
}
finally {
    if (Restore-Politique) { Write-Host "`n  Politique de correctifs restaurée (interruption)." -ForegroundColor Yellow }
}
