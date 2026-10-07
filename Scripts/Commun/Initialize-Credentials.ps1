<#
.SYNOPSIS
    Enregistre une fois pour toutes les identifiants de chaque poste, chiffrés.
.DESCRIPTION
    Pour chaque poste joignable de computers.txt, demande le mot de passe du
    compte d'administration et l'enregistre dans credentials\<NOM>.xml
    (dossier credentials à la racine du projet).
    Le mot de passe est chiffré par DPAPI (Export-Clixml) : seul l'utilisateur
    Windows qui a lancé ce script, sur cette machine, peut le déchiffrer.
    Aucun mot de passe n'apparaît en clair dans les scripts.
.PARAMETER ComputerName
    Ne (ré)enregistre que les postes indiqués, par exemple après un changement de mot de passe.
.PARAMETER UserName
    Nom du compte local sur les postes (par défaut : admin).
.EXAMPLE
    .\Initialize-Credentials.ps1
    .\Initialize-Credentials.ps1 -ComputerName PC02
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$UserName = 'admin'
)

Import-Module (Join-Path $PSScriptRoot 'PatchManager.psm1') -Force -ErrorAction Stop

$paths            = Get-ProjectPaths
$inventoryPath    = $paths.Inventory
$credentialFolder = $paths.Credentials

if (-not (Test-Path $credentialFolder)) {
    New-Item -ItemType Directory -Path $credentialFolder | Out-Null
}

$computers = Get-ComputerInventory -Path $inventoryPath
if ($ComputerName) {
    $computers = $computers | Where-Object { $_.Name -in $ComputerName }
}

foreach ($c in $computers) {
    if (-not (Test-Connection -ComputerName $c.IP -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Host "$($c.Name) : injoignable, ignoré." -ForegroundColor Yellow
        continue
    }

    $cred = Get-Credential -UserName "$($c.Name)\$UserName" -Message "Mot de passe du compte $UserName sur $($c.Name) ($($c.IP))"
    if (-not $cred) {
        Write-Host "$($c.Name) : saisie annulée, ignoré." -ForegroundColor Yellow
        continue
    }

    $file = Join-Path $credentialFolder "$($c.Name).xml"
    $cred | Export-Clixml -Path $file
    Write-Host "$($c.Name) : identifiants enregistrés (chiffrés) dans $file" -ForegroundColor Green
}
