<#
.SYNOPSIS
    Module commun du projet Patch Management.
.DESCRIPTION
    Regroupe les fonctions réutilisées par tous les scripts du projet :
      - Get-ProjectPaths          : chemins des dossiers et fichiers du projet
      - Get-ComputerInventory    : lecture de computers.txt
      - Get-RequiredPatches      : lecture de required-patches.txt
      - Test-ComputerAvailability : test ping + WinRM d'un poste
      - Get-StoredCredential     : chargement des identifiants chiffrés d'un poste
      - Export-ReportCsv         : export CSV robuste (fichier verrouillé par Excel)
      - Write-PatchLog           : ajout d'une ligne au journal PatchManager.log
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

function Get-RequiredPatches {
    <#
    .SYNOPSIS
        Lit la liste des correctifs obligatoires (un numéro de KB par ligne).
        Les lignes vides et les commentaires (#) sont ignorés, les numéros sont
        mis en majuscules et dédoublonnés. Une ligne qui n'est pas un numéro de KB
        valide (KB suivi de chiffres) est signalée puis ignorée.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Liste des correctifs obligatoires introuvable : $Path"
    }

    $kbs = Get-Content -Path $Path |
        ForEach-Object { ($_ -split '#')[0].Trim().ToUpper() } |
        Where-Object { $_ -ne '' } |
        ForEach-Object {
            if ($_ -match '^KB\d+$') { $_ }
            else { Write-Warning "Ligne ignorée (numéro de KB invalide) : $_" }
        } |
        Select-Object -Unique

    if (-not $kbs) {
        throw "Aucun correctif obligatoire valide dans $Path"
    }
    @($kbs)
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

function Export-ReportCsv {
    <#
    .SYNOPSIS
        Exporte des objets en CSV (séparateur ;, UTF-8 avec BOM, lisible par Excel en français).
    .DESCRIPTION
        Si le fichier cible est verrouillé (typiquement ouvert dans Excel), les résultats ne
        sont pas perdus : ils sont écrits dans un fichier horodaté à côté, par exemple
        ComplianceReport_20261007_185119.csv, et un avertissement est affiché.
    .OUTPUTS
        Le chemin du fichier réellement écrit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )

    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    try {
        $InputObject | Export-Csv -Path $Path -Delimiter ';' -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        return $Path
    }
    catch {
        $nom = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        $alt = Join-Path $dir ('{0}_{1}.csv' -f $nom, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Write-Warning "Impossible d'écrire $Path (fichier ouvert dans Excel ?). Résultats enregistrés dans $alt"
        $InputObject | Export-Csv -Path $alt -Delimiter ';' -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        return $alt
    }
}

function Write-PatchLog {
    <#
    .SYNOPSIS
        Ajoute une ligne horodatée au journal du projet (Rapports\PatchManager.log par défaut).
        Format : "jj/mm/aaaa hh:mm:ss ; message", par exemple :
          07/10/2026 19:05:12 ; PC02 ; Non conforme ; KB5054156
    .NOTES
        Une erreur d'écriture dans le journal est signalée mais n'interrompt jamais l'audit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Path
    )

    if (-not $Path) { $Path = (Get-ProjectPaths).Log }
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    $ligne = '{0} ; {1}' -f (Get-Date -Format 'dd/MM/yyyy HH:mm:ss'), $Message
    try {
        Add-Content -Path $Path -Value $ligne -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Warning "Écriture impossible dans le journal $Path : $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Get-ProjectPaths, Get-ComputerInventory, Get-RequiredPatches, Test-ComputerAvailability, Get-StoredCredential, Export-ReportCsv, Write-PatchLog
