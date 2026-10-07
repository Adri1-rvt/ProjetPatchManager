<#
.SYNOPSIS
    Partie 3 - Inventaire des correctifs installés.
.DESCRIPTION
    1. Affiche les correctifs installés sur la machine locale (poste d'administration).
    2. Récupère à distance, via PowerShell Remoting, les correctifs de chaque poste
       de computers.txt ; les postes inaccessibles sont ignorés proprement.
    3. Regroupe le tout dans Rapports\PatchesInventory.csv, trié par poste puis par
       date d'installation décroissante.
    4. Affiche pour chaque poste : nombre de correctifs, date et KB du plus récent.
       Cette synthèse est aussi exportée dans Rapports\PatchesSummary.csv.
.EXAMPLE
    .\Partie3-Correctifs.ps1
.EXAMPLE
    .\Partie3-Correctifs.ps1 -SkipLocal     # sans l'affichage des correctifs locaux
#>
[CmdletBinding()]
param(
    [switch]$SkipLocal
)

Import-Module (Join-Path $PSScriptRoot '..\Commun\PatchManager.psm1') -Force -ErrorAction Stop

$paths            = Get-ProjectPaths
$inventoryPath    = $paths.Inventory
$credentialFolder = $paths.Credentials
$reportFolder     = $paths.Reports
$patchesCsv       = Join-Path $reportFolder 'PatchesInventory.csv'
$summaryCsv       = Join-Path $reportFolder 'PatchesSummary.csv'

if (-not (Test-Path $reportFolder)) { New-Item -ItemType Directory -Path $reportFolder | Out-Null }

# Bloc commun : liste des correctifs avec les informations demandées.
# InstalledBy est souvent vide : Get-HotFix (classe Win32_QuickFixEngineering) ne le renseigne pas toujours.
$listeCorrectifs = {
    Get-HotFix | ForEach-Object {
        [PSCustomObject]@{
            KB               = $_.HotFixID
            Description      = $_.Description
            DateInstallation = $_.InstalledOn
            InstallePar      = if ($_.InstalledBy) { $_.InstalledBy } else { 'Non disponible' }
        }
    }
}

# --- Points 1 et 2 : correctifs de la machine locale ---
if (-not $SkipLocal) {
    Write-Host "`n=== Correctifs installés sur la machine locale ($env:COMPUTERNAME) ===" -ForegroundColor Cyan
    & $listeCorrectifs |
        Sort-Object DateInstallation -Descending |
        Format-Table KB, Description,
            @{ Label = 'Date d''installation'; Expression = { if ($_.DateInstallation) { $_.DateInstallation.ToString('dd/MM/yyyy') } else { 'Inconnue' } } },
            @{ Label = 'Installé par'; Expression = { $_.InstallePar } } -AutoSize
}

# --- Points 3 et 4 : collecte à distance sur tous les postes ---
Write-Host "=== Collecte des correctifs sur le parc ===" -ForegroundColor Cyan
$computers = Get-ComputerInventory -Path $inventoryPath
$correctifs = [System.Collections.Generic.List[object]]::new()
$synthese   = [System.Collections.Generic.List[object]]::new()

foreach ($c in $computers) {
    Write-Host "  $($c.Name) ($($c.IP)) : " -NoNewline

    $resume = [PSCustomObject][ordered]@{
        Poste           = $c.Name
        AdresseIP       = $c.IP
        Etat            = 'Inaccessible'
        NbCorrectifs    = $null
        DateDernier     = $null
        DerniereKB      = $null
        Erreur          = $null
    }

    $test = Test-ComputerAvailability -Computer $c
    if ($test.Etat -ne 'Accessible') {
        $resume.Erreur = $test.Erreur
        Write-Host "ignoré ($($test.Erreur))" -ForegroundColor Yellow
        $synthese.Add($resume)
        continue
    }

    $cred = Get-StoredCredential -ComputerName $c.Name -CredentialFolder $credentialFolder
    if (-not $cred) {
        $resume.Etat   = 'Erreur'
        $resume.Erreur = 'Identifiants absents (lancer Initialize-Credentials.ps1)'
        Write-Host 'identifiants absents' -ForegroundColor Red
        $synthese.Add($resume)
        continue
    }

    try {
        $liste = @(Invoke-Command -ComputerName $c.IP -Credential $cred -ScriptBlock $listeCorrectifs -ErrorAction Stop)

        foreach ($p in $liste) {
            $correctifs.Add([PSCustomObject][ordered]@{
                Poste            = $c.Name
                AdresseIP        = $c.IP
                KB               = $p.KB
                Description      = $p.Description
                DateInstallation = $p.DateInstallation
                InstallePar      = $p.InstallePar
            })
        }

        $dernier = $liste | Where-Object DateInstallation | Sort-Object DateInstallation -Descending | Select-Object -First 1
        $resume.Etat         = 'Accessible'
        $resume.NbCorrectifs = $liste.Count
        $resume.DateDernier  = $dernier.DateInstallation
        $resume.DerniereKB   = $dernier.KB
        Write-Host "$($liste.Count) correctif(s)" -ForegroundColor Green
    }
    catch {
        $resume.Etat   = 'Erreur'
        $resume.Erreur = "Collecte échouée : $($_.Exception.Message)"
        Write-Host 'erreur de collecte' -ForegroundColor Red
    }

    $synthese.Add($resume)
}

# --- Points 5 et 6 : inventaire trié et export CSV ---
$correctifsTries = $correctifs | Sort-Object Poste, @{ Expression = 'DateInstallation'; Descending = $true }

$formatDate = { param($d) if ($d) { ([datetime]$d).ToString('dd/MM/yyyy') } else { '' } }

$correctifsTries |
    Select-Object Poste, AdresseIP, KB, Description,
        @{ Name = 'DateInstallation'; Expression = { & $formatDate $_.DateInstallation } },
        InstallePar |
    Export-Csv -Path $patchesCsv -Delimiter ';' -NoTypeInformation -Encoding UTF8

$synthese |
    Select-Object Poste, AdresseIP, Etat, NbCorrectifs,
        @{ Name = 'DateDernier'; Expression = { & $formatDate $_.DateDernier } },
        DerniereKB, Erreur |
    Export-Csv -Path $summaryCsv -Delimiter ';' -NoTypeInformation -Encoding UTF8

Write-Host "`n=== Inventaire des correctifs (trié par poste puis date décroissante) ===" -ForegroundColor Cyan
$correctifsTries | Format-Table Poste,
    @{ Label = 'Adresse IP'; Expression = { $_.AdresseIP } },
    KB, Description,
    @{ Label = 'Date d''installation'; Expression = { & $formatDate $_.DateInstallation } } -AutoSize

Write-Host "=== Synthèse par poste ===" -ForegroundColor Cyan
$synthese | Format-Table Poste,
    @{ Label = 'Nb correctifs';       Expression = { if ($null -ne $_.NbCorrectifs) { $_.NbCorrectifs } else { '—' } } },
    @{ Label = 'Correctif le plus récent'; Expression = { if ($_.DateDernier) { & $formatDate $_.DateDernier } else { '—' } } },
    @{ Label = 'Dernière KB';         Expression = { if ($_.DerniereKB) { $_.DerniereKB } else { '—' } } },
    Etat -AutoSize

Write-Host "Fichiers produits :" -ForegroundColor Cyan
Write-Host "  $patchesCsv"
Write-Host "  $summaryCsv"
