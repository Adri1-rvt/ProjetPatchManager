<#
.SYNOPSIS
    Partie 1 - Lecture de l'inventaire et test de disponibilité des postes.
.DESCRIPTION
    Lit Config\computers.txt (format NOM;IP), puis teste chaque poste (ping, puis WinRM).
    Affiche pour chaque machine : nom, adresse IP, état de disponibilité.
    Les fonctions de lecture et de test sont fournies par le module commun PatchManager.psm1.
.EXAMPLE
    .\Partie1-Disponibilite.ps1
#>
[CmdletBinding()]
param(
    [string]$InventoryPath
)

Import-Module (Join-Path $PSScriptRoot '..\Commun\PatchManager.psm1') -Force -ErrorAction Stop
if (-not $InventoryPath) { $InventoryPath = (Get-ProjectPaths).Inventory }

$computers = Get-ComputerInventory -Path $InventoryPath
Write-Host "$(@($computers).Count) poste(s) trouvé(s) dans l'inventaire.`n" -ForegroundColor Cyan

$results = foreach ($c in $computers) {
    $t = Test-ComputerAvailability -Computer $c
    [PSCustomObject]@{
        Poste        = $t.Name
        'Adresse IP' = $t.IP
        Etat         = $t.Etat
        Detail       = if ($t.Erreur) { $t.Erreur } else { 'Ping et WinRM OK' }
    }
}

# Affichage coloré
foreach ($r in $results) {
    $color = if ($r.Etat -eq 'Accessible') { 'Green' } else { 'Red' }
    Write-Host ("{0,-8} {1,-16} {2,-13} {3}" -f $r.Poste, $r.'Adresse IP', $r.Etat, $r.Detail) -ForegroundColor $color
}

# On renvoie aussi les objets (réutilisables par d'autres scripts)
$results
