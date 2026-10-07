<#
.SYNOPSIS
    Enregistre, chiffré, le mot de passe du compte e-mail utilisé pour les notifications.
.DESCRIPTION
    Lit l'adresse d'expédition dans Config\notification.json, demande le mot de passe
    (pour Gmail ou iCloud : un "mot de passe d'application", jamais le mot de passe
    principal du compte) et l'enregistre dans credentials\smtp.xml avec Export-Clixml.
    Le mot de passe est chiffré par DPAPI : seul l'utilisateur Windows courant, sur ce
    poste, peut le déchiffrer. Il n'apparaît jamais en clair dans un script.
.EXAMPLE
    .\Initialize-MailCredential.ps1
#>
[CmdletBinding()]
param()

Import-Module (Join-Path $PSScriptRoot 'PatchManager.psm1') -Force -ErrorAction Stop
$paths = Get-ProjectPaths

if (-not (Test-Path $paths.MailConfig)) {
    throw "Configuration introuvable : $($paths.MailConfig)"
}
$config = Get-Content $paths.MailConfig -Raw -Encoding UTF8 | ConvertFrom-Json

$dir = Split-Path $paths.MailCredential -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

$cred = Get-Credential -UserName $config.From -Message "Mot de passe d'application du compte $($config.From) (serveur $($config.SmtpServer))"
if (-not $cred) {
    Write-Host 'Saisie annulée, rien n''a été enregistré.' -ForegroundColor Yellow
    return
}

$cred | Export-Clixml -Path $paths.MailCredential
Write-Host "Identifiants SMTP enregistrés (chiffrés) dans $($paths.MailCredential)" -ForegroundColor Green
