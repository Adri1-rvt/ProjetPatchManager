<#
.SYNOPSIS
    Partie 8 - Diagnostic du point de terminaison JEA « PatchManagement ».
.DESCRIPTION
    Pour chaque poste (ou ceux indiqués), sans rien modifier :
      1. avec le compte d'administration : présence et droits du point de terminaison,
         fichiers du module JEA, contenu du fichier de configuration, dernières erreurs WinRM ;
      2. avec le compte de service : connexion au point de terminaison standard puis au
         point de terminaison JEA, avec le message d'erreur complet en cas d'échec.
.PARAMETER ComputerName
    Postes à diagnostiquer (par défaut : tous ceux de computers.txt).
.EXAMPLE
    .\Diagnostic-JEA.ps1
    .\Diagnostic-JEA.ps1 -ComputerName PC01
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName
)

Import-Module (Join-Path $PSScriptRoot '..\Commun\PatchManager.psm1') -Force -ErrorAction Stop
$paths     = Get-ProjectPaths
$computers = Get-ComputerInventory -Path $paths.Inventory
if ($ComputerName) { $computers = $computers | Where-Object { $_.Name -in $ComputerName } }

function Write-Titre($texte) { Write-Host "`n--- $texte ---" -ForegroundColor Cyan }

foreach ($c in $computers) {
    Write-Host "`n===================== $($c.Name) ($($c.IP)) =====================" -ForegroundColor Cyan
    $test = Test-ComputerAvailability -Computer $c
    if ($test.Etat -ne 'Accessible') { Write-Host "Ignoré : $($test.Erreur)" -ForegroundColor Yellow; continue }

    $admin = Get-StoredCredential -ComputerName $c.Name -CredentialFolder $paths.Credentials -Admin
    $svc   = Get-StoredCredential -ComputerName $c.Name -CredentialFolder $paths.Credentials

    # ---------- 1. Vue administrateur ----------
    if ($admin) {
        try {
            Invoke-Command -ComputerName $c.IP -Credential $admin -ErrorAction Stop -ScriptBlock {
                Write-Host "`n--- Point de terminaison PatchManagement ---" -ForegroundColor Cyan
                $cfg = Get-PSSessionConfiguration -Name PatchManagement -ErrorAction SilentlyContinue
                if ($cfg) {
                    $cfg | Format-List Name, Permission, RunAsVirtualAccount, SessionType, ConfigFilePath | Out-String | Write-Host
                } else {
                    Write-Host 'ABSENT : le point de terminaison n''est pas enregistré' -ForegroundColor Red
                }

                Write-Host '--- Fichiers du module JEA ---' -ForegroundColor Cyan
                $base = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\PatchManagementJEA'
                if (Test-Path $base) { Get-ChildItem $base -Recurse -File | ForEach-Object { Write-Host "  $($_.FullName)" } }
                else { Write-Host '  Dossier du module absent' -ForegroundColor Red }

                Write-Host '--- Fichier de configuration (.pssc) ---' -ForegroundColor Cyan
                $pssc = Join-Path $env:ProgramData 'JEA\PatchManagement.pssc'
                if (Test-Path $pssc) {
                    Get-Content $pssc | Where-Object { $_ -match '^\s*(SessionType|RunAsVirtualAccount|TranscriptDirectory|RoleDefinitions|LanguageMode)' } |
                        ForEach-Object { Write-Host "  $($_.Trim())" }
                } else { Write-Host '  Fichier absent' -ForegroundColor Red }

                Write-Host '--- Membres de Utilisateurs de gestion à distance ---' -ForegroundColor Cyan
                Get-LocalGroupMember -SID 'S-1-5-32-580' | ForEach-Object { Write-Host "  $($_.Name)" }

                Write-Host '--- 5 dernières erreurs ou avertissements WinRM ---' -ForegroundColor Cyan
                Get-WinEvent -LogName 'Microsoft-Windows-WinRM/Operational' -MaxEvents 200 -ErrorAction SilentlyContinue |
                    Where-Object { $_.Level -in 2, 3 } | Select-Object -First 5 | ForEach-Object {
                        $msg = ($_.Message -split "`n")[0]
                        Write-Host ("  {0:dd/MM HH:mm:ss}  [{1}]  {2}" -f $_.TimeCreated, $_.Id, $msg)
                    }
            }
        }
        catch { Write-Host "Connexion administrateur impossible : $($_.Exception.Message)" -ForegroundColor Red }
    }
    else {
        Write-Host 'Identifiants d''administration absents (credentials\<NOM>.admin.xml)' -ForegroundColor Yellow
    }

    # ---------- 2. Vue compte de service ----------
    if (-not $svc) { Write-Host 'Identifiants du compte de service absents' -ForegroundColor Red; continue }

    Write-Titre "Compte de service ($($svc.UserName)) : point de terminaison standard"
    try {
        $id = Invoke-Command -ComputerName $c.IP -Credential $svc -ErrorAction Stop -ScriptBlock {
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        }
        Write-Host "  Connexion OK, session ouverte en tant que $id" -ForegroundColor Green
    }
    catch { Write-Host "  ÉCHEC : $($_.Exception.Message)" -ForegroundColor Red }

    Write-Titre "Compte de service ($($svc.UserName)) : point de terminaison JEA PatchManagement"
    try {
        $cmds = Invoke-Command -ComputerName $c.IP -Credential $svc -ConfigurationName PatchManagement -ErrorAction Stop -ScriptBlock { Get-Command }
        Write-Host "  Connexion OK. Commandes visibles : $(($cmds | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Green
    }
    catch {
        Write-Host '  ÉCHEC, message complet :' -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)"
        Write-Host "  Identifiant de l'erreur : $($_.FullyQualifiedErrorId)" -ForegroundColor DarkGray
    }
}
