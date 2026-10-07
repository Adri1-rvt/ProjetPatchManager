<#
.SYNOPSIS
    Partie 2 - Inventaire du parc.
.DESCRIPTION
    Pour chaque poste de computers.txt :
      1. teste l'accessibilité (ping puis WinRM) ;
      2. pour les postes accessibles, collecte à distance via PowerShell Remoting :
         modèle, BIOS, version et édition de Windows, architecture, dernier démarrage,
         RAM, espace disque système, mises à jour installées et état de Windows Update ;
      3. enregistre l'erreur rencontrée si un poste est inaccessible ou si la collecte échoue,
         sans interrompre le traitement des autres postes ;
      4. affiche un tableau récapitulatif et exporte l'inventaire en CSV.
.PARAMETER OutputPath
    Fichier CSV produit (par défaut : Rapports\Inventaire.csv à la racine du projet).
.EXAMPLE
    .\Partie2-Inventaire.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputPath
)

Import-Module (Join-Path $PSScriptRoot '..\Commun\PatchManager.psm1') -Force -ErrorAction Stop

$paths            = Get-ProjectPaths
$inventoryPath    = $paths.Inventory
$credentialFolder = $paths.Credentials
if (-not $OutputPath) { $OutputPath = Join-Path $paths.Reports 'Inventaire.csv' }
$dateControle     = Get-Date

# Bloc exécuté SUR chaque poste distant : il ne renvoie que des valeurs simples
$collecte = {
    $os   = Get-CimInstance Win32_OperatingSystem
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($os.SystemDrive)'"
    $ver  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $wu   = Get-Service wuauserv

    # Certains correctifs n'ont pas de date d'installation : on les compte, mais on ne les trie pas
    $hotfixes = @(Get-HotFix)
    $dernier  = $hotfixes | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1

    [PSCustomObject]@{
        NomMachine       = $cs.Name
        Fabricant        = $cs.Manufacturer
        Modele           = $cs.Model
        BIOS             = $bios.SMBIOSBIOSVersion
        Windows          = $os.Caption -replace '^Microsoft\s+', ''
        VersionWindows   = "$($ver.DisplayVersion) (build $($os.BuildNumber))"
        Architecture     = $os.OSArchitecture
        DernierDemarrage = $os.LastBootUpTime
        RAM_Go           = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        DisqueLibre_Go   = [math]::Round($disk.FreeSpace / 1GB, 1)
        DisqueTotal_Go   = [math]::Round($disk.Size / 1GB, 1)
        NbMisesAJour     = $hotfixes.Count
        DerniereMiseAJour = $dernier.InstalledOn
        DerniereKB       = $dernier.HotFixID
        WindowsUpdate    = [string]$wu.Status
        WindowsUpdateDemarrage = [string]$wu.StartType
    }
}

# Objet "vide" : même structure pour tous les postes, accessibles ou non
function New-InventoryRecord {
    param($Computer)
    [PSCustomObject][ordered]@{
        Poste             = $Computer.Name
        AdresseIP         = $Computer.IP
        Etat              = 'Inaccessible'
        NomMachine        = $null
        Fabricant         = $null
        Modele            = $null
        BIOS              = $null
        Windows           = $null
        VersionWindows    = $null
        Architecture      = $null
        DernierDemarrage  = $null
        RAM_Go            = $null
        DisqueLibre_Go    = $null
        DisqueTotal_Go    = $null
        NbMisesAJour      = $null
        DerniereMiseAJour = $null
        DerniereKB        = $null
        WindowsUpdate     = $null
        WindowsUpdateDemarrage = $null
        Erreur            = $null
        DateControle      = $dateControle
    }
}

$computers = Get-ComputerInventory -Path $inventoryPath
Write-Host "Inventaire de $(@($computers).Count) poste(s)...`n" -ForegroundColor Cyan

$inventaire = foreach ($c in $computers) {
    $record = New-InventoryRecord -Computer $c
    Write-Host "  $($c.Name) ($($c.IP)) : " -NoNewline

    # 1. Accessibilité
    $test = Test-ComputerAvailability -Computer $c
    if ($test.Etat -ne 'Accessible') {
        $record.Erreur = $test.Erreur
        Write-Host "inaccessible ($($test.Erreur))" -ForegroundColor Red
        $record
        continue
    }

    # 2. Identifiants
    $cred = Get-StoredCredential -ComputerName $c.Name -CredentialFolder $credentialFolder
    if (-not $cred) {
        $record.Etat   = 'Erreur'
        $record.Erreur = 'Identifiants absents (lancer Initialize-Credentials.ps1)'
        Write-Host 'identifiants absents' -ForegroundColor Red
        $record
        continue
    }

    # 3. Collecte distante : une erreur sur ce poste n'arrête pas le script
    try {
        $info = Invoke-Command -ComputerName $c.IP -Credential $cred -ScriptBlock $collecte -ErrorAction Stop
        $record.Etat = 'Accessible'
        foreach ($prop in 'NomMachine', 'Fabricant', 'Modele', 'BIOS', 'Windows', 'VersionWindows',
                          'Architecture', 'DernierDemarrage', 'RAM_Go', 'DisqueLibre_Go', 'DisqueTotal_Go',
                          'NbMisesAJour', 'DerniereMiseAJour', 'DerniereKB', 'WindowsUpdate', 'WindowsUpdateDemarrage') {
            $record.$prop = $info.$prop
        }
        Write-Host 'OK' -ForegroundColor Green
    }
    catch {
        $record.Etat   = 'Erreur'
        $record.Erreur = "Collecte échouée : $($_.Exception.Message)"
        Write-Host 'erreur de collecte' -ForegroundColor Red
    }

    $record
}

# 4. Tableau récapitulatif
Write-Host ''
$inventaire | Format-Table -AutoSize -Property `
    Poste,
    @{ Label = 'Adresse IP';        Expression = { $_.AdresseIP } },
    Windows,
    Architecture,
    @{ Label = 'Dernier démarrage'; Expression = { if ($_.DernierDemarrage) { $_.DernierDemarrage.ToString('dd/MM/yyyy') } else { '—' } } },
    @{ Label = 'Windows Update';    Expression = { if ($_.WindowsUpdate) { $_.WindowsUpdate } else { '—' } } },
    Etat

# 5. Export CSV (séparateur ; pour Excel en français)
$outDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$inventaire | Export-Csv -Path $OutputPath -Delimiter ';' -NoTypeInformation -Encoding UTF8
Write-Host "Inventaire exporté : $OutputPath" -ForegroundColor Cyan
