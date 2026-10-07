<#
.SYNOPSIS
    Module commun du projet Patch Management.
.DESCRIPTION
    Regroupe les fonctions réutilisées par tous les scripts du projet :
      - Get-ProjectPaths          : chemins des dossiers et fichiers du projet
      - Get-ComputerInventory    : lecture de computers.txt
      - Test-ComputerAvailability : test ping + WinRM d'un poste
      - Get-StoredCredential     : chargement des identifiants chiffrés d'un poste
    Emplacement attendu : Scripts\Commun\PatchManager.psm1
    Chargement depuis un script situé dans Scripts\PartieN :
      Import-Module (Join-Path $PSScriptRoot '..\Commun\PatchManager.psm1') -Force -ErrorAction Stop
#>

function Get-ProjectPaths {
    <#
    .SYNOPSIS
        Renvoie les chemins du projet, calculés à partir de l'emplacement du module.
        Les scripts n'ont ainsi aucun chemin écrit en dur : seul ce module connaît
        l'organisation des dossiers.
    .NOTES
        Arborescence :
          ProjetPatchManager\
            Config\        computers.txt, required-patches.txt
            credentials\   identifiants chiffrés (exclu de Git)
            Rapports\      CSV, rapports HTML, journal
            Scripts\Commun\PatchManager.psm1   <- ce module
    #>
    # GetFullPath normalise le chemin (supprime les '..' éventuels du chemin d'import)
    $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $config  = Join-Path $root 'Config'
    $reports = Join-Path $root 'Rapports'

    [PSCustomObject]@{
        Root            = $root
        Config          = $config
        Inventory       = Join-Path $config 'computers.txt'
        RequiredPatches = Join-Path $config 'required-patches.txt'
        Credentials     = Join-Path $root 'credentials'
        Reports         = $reports
        Log             = Join-Path $reports 'PatchManager.log'
    }
}

function Get-ComputerInventory {
    <#
    .SYNOPSIS
        Lit le fichier d'inventaire (format NOM;IP) et renvoie un objet par poste.
        Les lignes vides et les commentaires (#) sont ignorés.
    #>
    [CmdletBinding()]
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
    <#
    .SYNOPSIS
        Teste un poste en deux temps : ping (ICMP), puis service WinRM (Test-WSMan).
    .OUTPUTS
        Objet avec Name, IP, Ping, WinRM, Etat (Accessible / Inaccessible) et Erreur.
    .NOTES
        Si le ping échoue, WinRM n'est pas testé : cela évite d'attendre le délai
        d'expiration de WinRM sur une machine éteinte.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Computer)

    $result = [PSCustomObject]@{
        Name   = $Computer.Name
        IP     = $Computer.IP
        Ping   = $false
        WinRM  = $false
        Etat   = 'Inaccessible'
        Erreur = $null
    }

    $result.Ping = Test-Connection -ComputerName $Computer.IP -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $result.Ping) {
        $result.Erreur = 'Ping sans réponse'
        return $result
    }

    try {
        Test-WSMan -ComputerName $Computer.IP -ErrorAction Stop | Out-Null
        $result.WinRM = $true
        $result.Etat  = 'Accessible'
    }
    catch {
        $result.Erreur = 'WinRM inaccessible'
    }

    $result
}

function Get-StoredCredential {
    <#
    .SYNOPSIS
        Charge les identifiants chiffrés d'un poste (fichier credentials\<NOM>.xml).
        Renvoie $null si aucun fichier n'existe pour ce poste.
    .NOTES
        Les fichiers sont créés par Initialize-Credentials.ps1 avec Export-Clixml :
        le mot de passe est chiffré par DPAPI et ne peut être déchiffré que par
        le même utilisateur Windows, sur la même machine.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$CredentialFolder
    )

    $file = Join-Path $CredentialFolder "$ComputerName.xml"
    if (Test-Path $file) {
        Import-Clixml -Path $file
    }
    else {
        $null
    }
}

Export-ModuleMember -Function Get-ProjectPaths, Get-ComputerInventory, Test-ComputerAvailability, Get-StoredCredential
