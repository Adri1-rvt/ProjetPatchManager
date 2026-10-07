<#
.SYNOPSIS
    Partie 4 - Contrôle de conformité du parc.
.DESCRIPTION
    Compare les correctifs installés sur chaque poste avec la liste des correctifs
    obligatoires (Config\required-patches.txt) et attribue à chaque poste un état :
      - CONFORME      : tous les correctifs obligatoires sont installés ;
      - NON CONFORME  : au moins un correctif obligatoire manque ;
      - INACCESSIBLE  : le poste n'a pas pu être contrôlé (ping, WinRM ou collecte en échec).
    Affiche le détail des correctifs manquants, enregistre les résultats dans
    Rapports\ComplianceReport.csv et calcule le taux de conformité du parc
    (postes inaccessibles exclus du calcul).
.PARAMETER RequiredPatchesPath
    Liste des correctifs obligatoires à utiliser (par défaut : Config\required-patches.txt).
.EXAMPLE
    .\Partie4-Conformite.ps1
#>
[CmdletBinding()]
param(
    [string]$RequiredPatchesPath
)

Import-Module (Join-Path $PSScriptRoot '..\Commun\PatchManager.psm1') -Force -ErrorAction Stop

$paths = Get-ProjectPaths
if (-not $RequiredPatchesPath) { $RequiredPatchesPath = $paths.RequiredPatches }
$reportCsv = Join-Path $paths.Reports 'ComplianceReport.csv'
if (-not (Test-Path $paths.Reports)) { New-Item -ItemType Directory -Path $paths.Reports | Out-Null }

# --- Points 1 et 2 : lecture de la politique de correctifs ---
$required     = Get-RequiredPatches -Path $RequiredPatchesPath
$computers    = Get-ComputerInventory -Path $paths.Inventory
$dateControle = Get-Date

Write-Host "`nContrôle de conformité du $($dateControle.ToString('dd/MM/yyyy à HH:mm:ss'))" -ForegroundColor Cyan
Write-Host "Correctifs obligatoires ($($required.Count)) : $($required -join ', ')`n"

# --- Points 2 et 3 : comparaison poste par poste ---
$resultats = foreach ($c in $computers) {
    Write-Host "  $($c.Name) ($($c.IP)) : " -NoNewline

    $r = [PSCustomObject][ordered]@{
        Poste             = $c.Name
        AdresseIP         = $c.IP
        KBRequises        = $required.Count
        KBManquantes      = $null
        ListeKBManquantes = $null
        Etat              = 'INACCESSIBLE'
        Detail            = $null
        DateControle      = $dateControle.ToString('dd/MM/yyyy HH:mm:ss')
    }

    $test = Test-ComputerAvailability -Computer $c
    if ($test.Etat -ne 'Accessible') {
        $r.Detail = $test.Erreur
        Write-Host "INACCESSIBLE ($($test.Erreur))" -ForegroundColor Red
        $r
        continue
    }

    $cred = Get-StoredCredential -ComputerName $c.Name -CredentialFolder $paths.Credentials
    if (-not $cred) {
        $r.Detail = 'Identifiants absents (lancer Initialize-Credentials.ps1)'
        Write-Host 'INACCESSIBLE (identifiants absents)' -ForegroundColor Red
        $r
        continue
    }

    try {
        $installes = @((Invoke-PatchAudit -Computer $c -Credential $cred).Correctifs | ForEach-Object { $_.KB })
    }
    catch {
        $r.Detail = "Collecte échouée : $($_.Exception.Message)"
        Write-Host 'INACCESSIBLE (collecte échouée)' -ForegroundColor Red
        $r
        continue
    }

    $manquants = @($required | Where-Object { $_ -notin $installes })
    $r.KBManquantes      = $manquants.Count
    $r.ListeKBManquantes = $manquants -join ', '

    if ($manquants.Count -eq 0) {
        $r.Etat = 'CONFORME'
        Write-Host 'CONFORME' -ForegroundColor Green
    }
    else {
        $r.Etat = 'NON CONFORME'
        Write-Host "NON CONFORME ($($manquants.Count) correctif(s) manquant(s))" -ForegroundColor Yellow
    }
    $r
}

# --- Tableau récapitulatif ---
Write-Host ''
$resultats | Format-Table -AutoSize -Property Poste,
    @{ Label = 'KB requises';   Expression = { $_.KBRequises } },
    @{ Label = 'KB manquantes'; Expression = { if ($null -ne $_.KBManquantes) { $_.KBManquantes } else { '—' } } },
    @{ Label = 'État';          Expression = { $_.Etat } }

# --- Point 4 : détail des postes non conformes et inaccessibles ---
$nonConformes  = @($resultats | Where-Object Etat -eq 'NON CONFORME')
$inaccessibles = @($resultats | Where-Object Etat -eq 'INACCESSIBLE')

if ($nonConformes) {
    Write-Host 'Correctifs manquants par poste non conforme :' -ForegroundColor Yellow
    foreach ($nc in $nonConformes) {
        Write-Host "  $($nc.Poste) (contrôlé le $($nc.DateControle)) :"
        foreach ($kb in $nc.ListeKBManquantes -split ', ') { Write-Host "      - $kb manquante" }
    }
    Write-Host ''
}
if ($inaccessibles) {
    Write-Host 'Postes non contrôlés :' -ForegroundColor Red
    foreach ($i in $inaccessibles) { Write-Host "  $($i.Poste) : $($i.Detail)" }
    Write-Host ''
}

# --- Point 5 : export CSV ---
$fichier = Export-ReportCsv -InputObject $resultats -Path $reportCsv

# --- Point 6 : taux de conformité (postes inaccessibles exclus) ---
$conformes = @($resultats | Where-Object Etat -eq 'CONFORME').Count
$controles = $conformes + $nonConformes.Count

if ($controles -gt 0) {
    $taux = [math]::Round(100 * $conformes / $controles, 1)
    $couleur = if ($taux -eq 100) { 'Green' } elseif ($taux -ge 50) { 'Yellow' } else { 'Red' }
    Write-Host "Taux de conformité du parc : $taux % ($conformes poste(s) conforme(s) sur $controles contrôlé(s), $($inaccessibles.Count) inaccessible(s) exclu(s))" -ForegroundColor $couleur
}
else {
    Write-Host 'Taux de conformité : non calculable (aucun poste contrôlé)' -ForegroundColor Red
}

Write-Host "Résultats enregistrés : $fichier" -ForegroundColor Cyan
