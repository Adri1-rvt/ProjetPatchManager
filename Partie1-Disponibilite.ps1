<#
.SYNOPSIS
    Partie 1 - Lecture de l'inventaire et test de disponibilité des postes.
.DESCRIPTION
    Lit computers.txt (format NOM;IP), puis teste chaque poste par ICMP (ping).
    Affiche pour chaque machine : nom, adresse IP, état de disponibilité.
.EXAMPLE
    .\Partie1-Disponibilite.ps1
    .\Partie1-Disponibilite.ps1 -InventoryPath .\computers.txt
#>
[CmdletBinding()]
param(
    [string]$InventoryPath = (Join-Path $PSScriptRoot 'computers.txt')
)

function Get-ComputerInventory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Fichier d'inventaire introuvable : $Path"
    }

    Get-Content -Path $Path |
        Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') } |
        ForEach-Object {
            $parts = $_.Split(';')
            if ($parts.Count -lt 2) {
                Write-Warning "Ligne ignorée (format invalide) : $_"
                return
            }
            [PSCustomObject]@{
                Name = $parts[0].Trim()
                IP   = $parts[1].Trim()
            }
        }
}

function Test-ComputerAvailability {
    param([Parameter(Mandatory)][PSCustomObject]$Computer)

    $online = Test-Connection -ComputerName $Computer.IP -Count 1 -Quiet -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        Poste        = $Computer.Name
        'Adresse IP' = $Computer.IP
        Etat         = if ($online) { 'Accessible' } else { 'Inaccessible' }
    }
}

# --- Programme principal ---
$computers = Get-ComputerInventory -Path $InventoryPath
Write-Host "$(@($computers).Count) poste(s) trouvé(s) dans l'inventaire.`n" -ForegroundColor Cyan

$results = foreach ($c in $computers) {
    Test-ComputerAvailability -Computer $c
}

# Affichage coloré
foreach ($r in $results) {
    $color = if ($r.Etat -eq 'Accessible') { 'Green' } else { 'Red' }
    Write-Host ("{0,-8} {1,-16} {2}" -f $r.Poste, $r.'Adresse IP', $r.Etat) -ForegroundColor $color
}

# On renvoie aussi les objets (réutilisables dans les parties suivantes)
$results
