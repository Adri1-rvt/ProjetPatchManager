<#
.SYNOPSIS
    Partie 6 - Rapport de sécurité du parc.
.DESCRIPTION
    Réalise un audit complet du parc en une seule passe, pour que toutes les
    informations du rapport datent du même contrôle :
      - accessibilité de chaque poste (ping, WinRM) ;
      - version de Windows, dernier démarrage, service Windows Update ;
      - conformité par rapport à Config\required-patches.txt.
    Produit ensuite :
      - un rapport détaillé par poste       : Rapports\SecurityReport.csv
      - une version HTML du rapport          : Rapports\SecurityReport.html
      - une copie horodatée du rapport HTML  : Rapports\Historique\SecurityReport_<date>.html
      - le journal des exécutions            : Rapports\PatchManager.log
    Le rapport contient une synthèse globale du parc et une section dédiée aux
    postes nécessitant une intervention.
.EXAMPLE
    .\Partie6-RapportSecurite.ps1
#>
[CmdletBinding()]
param()

Import-Module (Join-Path $PSScriptRoot '..\Commun\PatchManager.psm1') -Force -ErrorAction Stop

$paths        = Get-ProjectPaths
$csvPath      = Join-Path $paths.Reports 'SecurityReport.csv'
$htmlPath     = Join-Path $paths.Reports 'SecurityReport.html'
$historique   = Join-Path $paths.Reports 'Historique'
$dateControle = Get-Date
$dateTexte    = $dateControle.ToString('dd/MM/yyyy HH:mm:ss')

foreach ($dir in $paths.Reports, $historique) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
}

$required  = Get-RequiredPatches -Path $paths.RequiredPatches
$computers = Get-ComputerInventory -Path $paths.Inventory

Write-PatchLog "Début de l'audit"
Write-Host "`nAudit de sécurité du parc - $dateTexte" -ForegroundColor Cyan
Write-Host "Correctifs obligatoires ($($required.Count)) : $($required -join ', ')`n"

# =====================================================================
# 1. Collecte et analyse, poste par poste
# =====================================================================
$rapport = foreach ($c in $computers) {
    Write-Host "  $($c.Name) ($($c.IP)) : " -NoNewline

    $r = [PSCustomObject][ordered]@{
        Poste             = $c.Name
        AdresseIP         = $c.IP
        Accessibilite     = 'Inaccessible'
        Windows           = $null
        DernierDemarrage  = $null
        ServiceWU         = $null
        DemarrageWU       = $null
        KBRequises        = $required.Count
        KBManquantes      = $null
        ListeKBManquantes = $null
        Conformite        = 'INACCESSIBLE'
        Intervention      = $true
        Motif             = $null
        DateControle      = $dateTexte
    }

    # Accessibilité
    $test = Test-ComputerAvailability -Computer $c
    if ($test.Etat -ne 'Accessible') {
        $r.Motif = $test.Erreur
        Write-PatchLog "$($c.Name) ; $($test.Erreur)"
        Write-Host "INACCESSIBLE ($($test.Erreur))" -ForegroundColor Red
        $r
        continue
    }
    $r.Accessibilite = 'Accessible'
    Write-PatchLog "$($c.Name) ; Accessible"

    # Identifiants
    $cred = Get-StoredCredential -ComputerName $c.Name -CredentialFolder $paths.Credentials
    if (-not $cred) {
        $r.Motif = 'Identifiants absents'
        Write-PatchLog "$($c.Name) ; ERREUR ; Identifiants absents"
        Write-Host 'INACCESSIBLE (identifiants absents)' -ForegroundColor Red
        $r
        continue
    }

    # Collecte distante
    try {
        $info = Invoke-PatchAudit -Computer $c -Credential $cred
    }
    catch {
        $r.Motif = "Collecte échouée : $($_.Exception.Message)"
        Write-PatchLog "$($c.Name) ; ERREUR ; Collecte échouée"
        Write-Host 'INACCESSIBLE (collecte échouée)' -ForegroundColor Red
        $r
        continue
    }

    $r.Windows          = "$($info.Windows) $($info.DisplayVersion)"
    $r.DernierDemarrage = $info.DernierDemarrage.ToString('dd/MM/yyyy HH:mm')
    $r.ServiceWU        = $info.ServiceWU
    $r.DemarrageWU      = $info.DemarrageWU

    # Conformité
    $kbInstallees = @($info.Correctifs | ForEach-Object { $_.KB })
    $manquants = @($required | Where-Object { $_ -notin $kbInstallees })
    $r.KBManquantes      = $manquants.Count
    $r.ListeKBManquantes = $manquants -join ', '

    $motifs = @()
    if ($manquants.Count -eq 0) {
        $r.Conformite = 'CONFORME'
        Write-PatchLog "$($c.Name) ; Conforme"
    }
    else {
        $r.Conformite = 'NON CONFORME'
        $motifs += "Correctif(s) manquant(s) : $($r.ListeKBManquantes)"
        Write-PatchLog "$($c.Name) ; Non conforme ; $($r.ListeKBManquantes)"
    }

    # Windows Update désactivé : le poste ne pourra plus recevoir de correctifs
    if ($r.DemarrageWU -eq 'Disabled') {
        $motifs += 'Service Windows Update désactivé'
        Write-PatchLog "$($c.Name) ; Alerte ; Service Windows Update désactivé"
    }

    $r.Intervention = $motifs.Count -gt 0
    $r.Motif        = $motifs -join ' ; '

    $couleur = if ($r.Conformite -eq 'CONFORME') { 'Green' } else { 'Yellow' }
    Write-Host $r.Conformite -ForegroundColor $couleur
    $r
}

# =====================================================================
# 2. Synthèse globale du parc
# =====================================================================
$accessibles   = @($rapport | Where-Object Accessibilite -eq 'Accessible').Count
$conformes     = @($rapport | Where-Object Conformite -eq 'CONFORME').Count
$nonConformes  = @($rapport | Where-Object Conformite -eq 'NON CONFORME').Count
$inaccessibles = @($rapport | Where-Object Conformite -eq 'INACCESSIBLE').Count
$totalManquant = ($rapport | Where-Object { $null -ne $_.KBManquantes } | Measure-Object KBManquantes -Sum).Sum
if (-not $totalManquant) { $totalManquant = 0 }
$controles     = $conformes + $nonConformes
$taux          = if ($controles -gt 0) { [math]::Round(100 * $conformes / $controles, 1) } else { $null }
$aIntervenir   = @($rapport | Where-Object Intervention)

$synthese = [ordered]@{
    'Nombre total de postes'               = @($rapport).Count
    'Nombre de postes accessibles'         = $accessibles
    'Nombre de postes inaccessibles'       = @($rapport).Count - $accessibles
    'Nombre de postes conformes'           = $conformes
    'Nombre de postes non conformes'       = $nonConformes
    'Nombre total de correctifs manquants' = $totalManquant
    'Taux de conformité'                   = if ($null -ne $taux) { "$taux %" } else { 'Non calculable' }
}

# =====================================================================
# 3. Affichage console (version courte ; le détail complet est dans le CSV et le HTML)
# =====================================================================
Write-Host "`n=== Rapport par poste ===" -ForegroundColor Cyan
$rapport | Format-Table -AutoSize Poste,
    @{ Label = 'Adresse IP';   Expression = { $_.AdresseIP } },
    @{ Label = 'Accès';        Expression = { $_.Accessibilite } },
    @{ Label = 'Windows';      Expression = { if ($_.Windows) { $_.Windows -replace 'Professionnel', 'Pro' } else { '—' } } },
    @{ Label = 'Démarrage';    Expression = { if ($_.DernierDemarrage) { $_.DernierDemarrage.Substring(0, 10) } else { '—' } } },
    @{ Label = 'Windows Update'; Expression = { if ($_.ServiceWU) { "$($_.ServiceWU) ($($_.DemarrageWU))" } else { '—' } } },
    @{ Label = 'Manquants';    Expression = { if ($null -ne $_.KBManquantes) { "$($_.KBManquantes)/$($_.KBRequises)" } else { '—' } } },
    @{ Label = 'Conformité';   Expression = { $_.Conformite } }

Write-Host '=== Synthèse du parc ===' -ForegroundColor Cyan
foreach ($k in $synthese.Keys) { Write-Host ('  {0,-38} : {1}' -f $k, $synthese[$k]) }

Write-Host "`n=== Postes nécessitant une intervention ===" -ForegroundColor Cyan
if ($aIntervenir) {
    foreach ($p in $aIntervenir) { Write-Host "  $($p.Poste) [$($p.Conformite)] : $($p.Motif)" -ForegroundColor Yellow }
}
else {
    Write-Host '  Aucune intervention nécessaire.' -ForegroundColor Green
}

# =====================================================================
# 4. Export CSV
# =====================================================================
$csvFile = Export-ReportCsv -InputObject $rapport -Path $csvPath

# =====================================================================
# 5. Version HTML
# =====================================================================
function ConvertTo-HtmlText([object]$Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return '&mdash;' }
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}
function Get-Badge([string]$Etat) {
    $classe = switch ($Etat) {
        'CONFORME'     { 'ok' }
        'NON CONFORME' { 'warn' }
        'Accessible'   { 'ok' }
        default        { 'ko' }
    }
    "<span class=""badge $classe"">$(ConvertTo-HtmlText $Etat)</span>"
}

$cartes = foreach ($k in $synthese.Keys) {
    "<div class=""card""><div class=""value"">$(ConvertTo-HtmlText $synthese[$k])</div><div class=""label"">$(ConvertTo-HtmlText ($k -replace '^Nombre (total )?de ', ''))</div></div>"
}

$lignesIntervention = if ($aIntervenir) {
    foreach ($p in $aIntervenir) {
        "<tr><td><strong>$(ConvertTo-HtmlText $p.Poste)</strong></td><td>$(ConvertTo-HtmlText $p.AdresseIP)</td><td>$(Get-Badge $p.Conformite)</td><td>$(ConvertTo-HtmlText $p.Motif)</td></tr>"
    }
}
else {
    '<tr><td colspan="4" class="none">Aucune intervention nécessaire.</td></tr>'
}

$lignesPostes = foreach ($p in $rapport) {
    $wu = if ($p.ServiceWU) { "$($p.ServiceWU) ($($p.DemarrageWU))" } else { $null }
    $manq = if ($null -ne $p.KBManquantes) { "$($p.KBManquantes) / $($p.KBRequises)" } else { $null }
    "<tr><td><strong>$(ConvertTo-HtmlText $p.Poste)</strong></td><td>$(ConvertTo-HtmlText $p.AdresseIP)</td><td>$(Get-Badge $p.Accessibilite)</td><td>$(ConvertTo-HtmlText $p.Windows)</td><td>$(ConvertTo-HtmlText $p.DernierDemarrage)</td><td>$(ConvertTo-HtmlText $wu)</td><td>$(ConvertTo-HtmlText $manq)</td><td>$(ConvertTo-HtmlText $p.ListeKBManquantes)</td><td>$(Get-Badge $p.Conformite)</td><td>$(ConvertTo-HtmlText $p.DateControle)</td></tr>"
}

$tauxLargeur = if ($null -ne $taux) { $taux } else { 0 }
$tauxClasse  = if ($null -eq $taux) { 'ko' } elseif ($taux -eq 100) { 'ok' } elseif ($taux -ge 50) { 'warn' } else { 'ko' }
$politique   = ($required | ForEach-Object { "<code>$(ConvertTo-HtmlText $_)</code>" }) -join ' '

$html = @"
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Rapport de sécurité du parc - $dateTexte</title>
<style>
  :root { --bg:#f6f7f9; --panel:#ffffff; --ink:#1d2330; --muted:#5b6475; --line:#e2e5ea;
          --ok:#1f8a4c; --ok-bg:#e3f4ea; --warn:#a35c00; --warn-bg:#fdf0dc; --ko:#b42318; --ko-bg:#fde7e5; --accent:#2457c5; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:"Segoe UI",system-ui,sans-serif; background:var(--bg); color:var(--ink); line-height:1.45; }
  header { background:#1d2330; color:#fff; padding:28px 32px; }
  header h1 { margin:0 0 6px; font-size:24px; font-weight:600; }
  header p { margin:0; color:#c3c9d4; font-size:14px; }
  main { max-width:1200px; margin:0 auto; padding:24px 32px 40px; }
  h2 { font-size:18px; margin:32px 0 12px; }
  .cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; }
  .card { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:14px 16px; }
  .card .value { font-size:24px; font-weight:600; }
  .card .label { font-size:13px; color:var(--muted); }
  .rate { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:16px; margin-top:12px; }
  .bar { height:12px; background:var(--line); border-radius:6px; overflow:hidden; margin-top:8px; }
  .bar span { display:block; height:100%; }
  .bar .ok { background:var(--ok); } .bar .warn { background:#e08a00; } .bar .ko { background:var(--ko); }
  table { width:100%; border-collapse:collapse; background:var(--panel); border:1px solid var(--line); border-radius:8px; overflow:hidden; font-size:14px; }
  th { text-align:left; background:#eef0f4; color:var(--muted); font-weight:600; padding:10px 12px; }
  td { padding:10px 12px; border-top:1px solid var(--line); vertical-align:top; }
  .badge { display:inline-block; padding:2px 8px; border-radius:10px; font-size:12px; font-weight:600; white-space:nowrap; }
  .badge.ok { color:var(--ok); background:var(--ok-bg); }
  .badge.warn { color:var(--warn); background:var(--warn-bg); }
  .badge.ko { color:var(--ko); background:var(--ko-bg); }
  .none { color:var(--ok); font-weight:600; }
  code { background:#eef0f4; padding:1px 6px; border-radius:4px; font-size:13px; }
  .scroll { overflow-x:auto; }
  footer { color:var(--muted); font-size:12px; margin-top:32px; }
</style>
</head>
<body>
<header>
  <h1>Rapport de sécurité du parc</h1>
  <p>Contrôle du $dateTexte &middot; $(@($rapport).Count) poste(s) audité(s) depuis $(ConvertTo-HtmlText $env:COMPUTERNAME)</p>
</header>
<main>
  <h2>Synthèse du parc</h2>
  <div class="cards">
    $($cartes -join "`n    ")
  </div>
  <div class="rate">
    <strong>Taux de conformité : $(ConvertTo-HtmlText $synthese['Taux de conformité'])</strong>
    <span style="color:var(--muted)"> &middot; $conformes conforme(s) sur $controles poste(s) contrôlé(s), postes inaccessibles exclus</span>
    <div class="bar"><span class="$tauxClasse" style="width:$($tauxLargeur.ToString([System.Globalization.CultureInfo]::InvariantCulture))%"></span></div>
  </div>

  <h2>Postes nécessitant une intervention ($($aIntervenir.Count))</h2>
  <div class="scroll"><table>
    <tr><th>Poste</th><th>Adresse IP</th><th>État</th><th>Motif</th></tr>
    $($lignesIntervention -join "`n    ")
  </table></div>

  <h2>Détail par poste</h2>
  <div class="scroll"><table>
    <tr><th>Poste</th><th>Adresse IP</th><th>Accessibilité</th><th>Windows</th><th>Dernier démarrage</th><th>Windows Update</th><th>KB manquantes</th><th>Liste des KB manquantes</th><th>Conformité</th><th>Contrôle</th></tr>
    $($lignesPostes -join "`n    ")
  </table></div>

  <h2>Politique de correctifs appliquée</h2>
  <p>$($required.Count) correctif(s) obligatoire(s) : $politique</p>

  <footer>Rapport généré automatiquement par Partie6-RapportSecurite.ps1 &middot; Journal : Rapports\PatchManager.log</footer>
</main>
</body>
</html>
"@

$horodatage  = $dateControle.ToString('yyyyMMdd_HHmmss')
$archivePath = Join-Path $historique "SecurityReport_$horodatage.html"
try {
    Set-Content -Path $htmlPath -Value $html -Encoding UTF8 -ErrorAction Stop
    $htmlFile = $htmlPath
}
catch {
    Write-Warning "Impossible d'écrire $htmlPath : $($_.Exception.Message)"
    $htmlFile = $null
}
Set-Content -Path $archivePath -Value $html -Encoding UTF8

Write-PatchLog 'Rapport généré'
Write-PatchLog "Fin de l'audit"

Write-Host "`nFichiers produits :" -ForegroundColor Cyan
Write-Host "  Rapport CSV  : $csvFile"
if ($htmlFile) { Write-Host "  Rapport HTML : $htmlFile" }
Write-Host "  Archive HTML : $archivePath"
Write-Host "  Journal      : $($paths.Log)"
