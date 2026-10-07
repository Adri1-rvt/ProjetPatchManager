<#
.SYNOPSIS
    Partie 1 - Point 6 : exécution distante non interactive avec Invoke-Command.
.DESCRIPTION
    Ouvre une session PowerShell distante vers chaque VM (comptes locaux différents),
    exécute le même bloc de commandes en parallèle sur toutes les sessions,
    puis affiche les résultats et ferme les sessions.
.EXAMPLE
    .\Partie1-InvokeCommand.ps1
#>

# Identifiants : une fenêtre demande le mot de passe pour chaque poste
$credPC01 = Get-Credential -UserName 'PC01\admin' -Message 'Mot de passe du compte admin de PC01'
$credPC02 = Get-Credential -UserName 'PC02\admin' -Message 'Mot de passe du compte admin de PC02'

# 1. Test simple sur un seul poste
Write-Host "`n--- Test sur PC01 seul ---" -ForegroundColor Cyan
Invoke-Command -ComputerName 192.168.93.11 -Credential $credPC01 -ScriptBlock {
    "Nom du poste      : $(hostname)"
    "Correctifs        : $((Get-HotFix).Count)"
}

# 2. Même bloc de commandes exécuté en parallèle sur les deux postes
Write-Host "`n--- Exécution parallèle sur PC01 et PC02 ---" -ForegroundColor Cyan
$s1 = New-PSSession -ComputerName 192.168.93.11 -Credential $credPC01
$s2 = New-PSSession -ComputerName 192.168.93.13 -Credential $credPC02

try {
    Invoke-Command -Session $s1, $s2 -ScriptBlock {
        [PSCustomObject]@{
            Poste         = $env:COMPUTERNAME
            NbCorrectifs  = (Get-HotFix).Count
            WindowsUpdate = (Get-Service wuauserv).Status
        }
    } | Format-Table Poste, NbCorrectifs, WindowsUpdate, PSComputerName -AutoSize
}
finally {
    # Les sessions sont toujours fermées, même en cas d'erreur
    Remove-PSSession $s1, $s2
}
