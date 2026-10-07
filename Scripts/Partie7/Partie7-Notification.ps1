<#
.SYNOPSIS
    Partie 7 - Notification de l'administrateur en cas d'anomalie.
.DESCRIPTION
    Lit le rapport de sécurité produit par la Partie 6 (Rapports\SecurityReport.csv) et
    détecte les postes NON CONFORMES ou INACCESSIBLES.
      - Aucune anomalie : le script se termine sans envoyer de notification.
      - Au moins une anomalie : un message récapitulatif est construit et envoyé par
        e-mail à l'administrateur, avec le rapport HTML et le rapport CSV en pièces jointes.
    Les paramètres d'envoi sont lus dans Config\notification.json ; le mot de passe est
    stocké chiffré dans credentials\smtp.xml (voir Initialize-MailCredential.ps1).
    Le résultat de l'envoi est tracé dans Rapports\PatchManager.log.
.PARAMETER RunAudit
    Lance d'abord un nouvel audit (Partie 6) pour notifier sur des données fraîches.
.PARAMETER DryRun
    Construit et affiche le message sans l'envoyer (test sans compte e-mail).
.EXAMPLE
    .\Partie7-Notification.ps1 -RunAudit
.EXAMPLE
    .\Partie7-Notification.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$RunAudit,
    [switch]$DryRun
)

Import-Module (Join-Path $PSScriptRoot '..\Commun\PatchManager.psm1') -Force -ErrorAction Stop
$paths    = Get-ProjectPaths
$csvPath  = Join-Path $paths.Reports 'SecurityReport.csv'
$htmlPath = Join-Path $paths.Reports 'SecurityReport.html'

# --- 0. Audit préalable (facultatif) ---
if ($RunAudit) {
    & (Join-Path $PSScriptRoot '..\Partie6\Partie6-RapportSecurite.ps1')
}

# --- 1. Lecture du rapport de la Partie 6 ---
if (-not (Test-Path $csvPath)) {
    throw "Rapport introuvable : $csvPath. Lancez d'abord la Partie 6, ou ce script avec -RunAudit."
}
$rapport = @(Import-Csv -Path $csvPath -Delimiter ';' -Encoding UTF8)

$age = (Get-Date) - (Get-Item $csvPath).LastWriteTime
if ($age.TotalHours -gt 24) {
    Write-Warning ("Le rapport date de plus de 24 h ({0:dd/MM/yyyy HH:mm}). Utilisez -RunAudit pour un audit à jour." -f (Get-Item $csvPath).LastWriteTime)
}

# --- 2. Détection des anomalies ---
$nonConformes  = @($rapport | Where-Object Conformite -eq 'NON CONFORME')
$inaccessibles = @($rapport | Where-Object Conformite -eq 'INACCESSIBLE')
$anomalies     = @($rapport | Where-Object { $_.Conformite -in 'NON CONFORME', 'INACCESSIBLE' })

if ($anomalies.Count -eq 0) {
    Write-Host 'Aucune anomalie détectée : aucune notification envoyée.' -ForegroundColor Green
    Write-PatchLog 'Aucune anomalie ; notification non nécessaire'
    exit 0
}

# --- 3. Construction du message ---
$dateControle = ($rapport | Select-Object -First 1).DateControle
$dateJour     = if ($dateControle) { $dateControle.Substring(0, 10) } else { (Get-Date -Format 'dd/MM/yyyy') }
$objet        = '[PATCH MANAGEMENT] Anomalies détectées'

$lignes = [System.Collections.Generic.List[string]]::new()
$lignes.Add("Date du contrôle : $dateJour")
$lignes.Add('')
$lignes.Add(('{0,-22}: {1}' -f 'Postes contrôlés',     $rapport.Count))
$lignes.Add(('{0,-22}: {1}' -f 'Postes non conformes', $nonConformes.Count))
$lignes.Add(('{0,-22}: {1}' -f 'Postes inaccessibles', $inaccessibles.Count))

foreach ($p in $anomalies) {
    $lignes.Add('')
    if ($p.Conformite -eq 'NON CONFORME') {
        $lignes.Add("$($p.Poste) : NON CONFORME")
        foreach ($kb in ($p.ListeKBManquantes -split ',\s*' | Where-Object { $_ })) {
            $lignes.Add("        $kb manquante")
        }
    }
    else {
        $cause = if ($p.Motif) { " ($($p.Motif))" } else { '' }
        $lignes.Add("$($p.Poste) : INACCESSIBLE$cause")
    }
}
$lignes.Add('')
$lignes.Add('Le rapport de sécurité complet est joint à ce message.')
$lignes.Add("Message envoyé automatiquement par Partie7-Notification.ps1 depuis $env:COMPUTERNAME.")
$corps = $lignes -join "`r`n"

Write-Host "`nObjet : $objet`n" -ForegroundColor Cyan
Write-Host $corps
Write-Host ''

# --- Mode test : pas d'envoi ---
if ($DryRun) {
    Write-Host 'Mode test (-DryRun) : le message n''a pas été envoyé.' -ForegroundColor Yellow
    Write-PatchLog "Simulation ; notification construite mais non envoyée ($($anomalies.Count) anomalie(s))"
    exit 0
}

# --- 4. Envoi ---
try {
    if (-not (Test-Path $paths.MailConfig))     { throw "Configuration introuvable : $($paths.MailConfig)" }
    if (-not (Test-Path $paths.MailCredential)) { throw 'Identifiants SMTP absents : lancez Scripts\Commun\Initialize-MailCredential.ps1' }

    $config = Get-Content $paths.MailConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    $cred   = Import-Clixml -Path $paths.MailCredential

    $pieces = @()
    if ($config.AttachReport) {
        $pieces = @($htmlPath, $csvPath) | Where-Object { Test-Path $_ }
    }

    # Windows PowerShell 5.1 peut négocier par défaut un ancien protocole TLS, refusé par Gmail ou iCloud
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $envoi = @{
        SmtpServer  = $config.SmtpServer
        Port        = $config.Port
        UseSsl      = [bool]$config.UseSsl
        Credential  = $cred
        From        = $config.From
        To          = @($config.To)
        Subject     = $objet
        Body        = $corps
        Encoding    = [System.Text.Encoding]::UTF8
        ErrorAction = 'Stop'
    }
    if ($pieces) { $envoi.Attachments = $pieces }

    Send-MailMessage @envoi -WarningAction SilentlyContinue

    $destinataires = @($config.To) -join ', '
    Write-Host "Notification envoyée à $destinataires" -ForegroundColor Green
    Write-PatchLog "Notification envoyée à $destinataires"
    exit 0
}
catch {
    Write-Host "Échec de l'envoi : $($_.Exception.Message)" -ForegroundColor Red
    Write-PatchLog "ERREUR ; Notification non envoyée ; $($_.Exception.Message)"
    exit 2
}
