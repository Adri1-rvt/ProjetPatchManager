# Projet Patch Manager – Gestion des mises à jour en PowerShell

Solution simplifiée de **Patch Management** pour un parc Windows, pilotée en PowerShell depuis un poste d'administration central via **PowerShell Remoting (WinRM)**.

Projet réalisé dans le cadre du module *Sécurité des systèmes* (EFREI, S7).

## Fonctionnalités

- Inventaire des postes à partir d'un fichier `computers.txt`
- Test d'accessibilité de chaque poste (ping, puis WinRM)
- Inventaire système : modèle, BIOS, version de Windows, RAM, disque, Windows Update
- Inventaire des correctifs installés sur chaque poste
- Gestion des postes inaccessibles sans interrompre l'exécution
- Export des résultats en CSV
- *À venir :* contrôle de conformité, rapport HTML, journalisation, notification

## Arborescence

```
ProjetPatchManager\
├── Config\            computers.txt (inventaire du parc)
├── credentials\       identifiants chiffrés (non versionné)
├── Rapports\          fichiers CSV produits par les scripts
├── Screenshots\       captures d'écran par partie
└── Scripts\
    ├── Commun\        PatchManager.psm1 (module commun), Initialize-Credentials.ps1
    ├── Partie1\       disponibilité des postes, tests Invoke-Command
    ├── Partie2\       inventaire du parc
    └── Partie3\       inventaire des correctifs
```

## Prérequis

- Un poste d'administration Windows avec Windows PowerShell 5.1
- Des postes supervisés Windows 10/11 **Pro ou Enterprise**, joignables sur le réseau
- Sur chaque poste supervisé, en administrateur :

```powershell
Enable-PSRemoting -Force
New-NetFirewallRule -DisplayName "WinRM - Poste admin uniquement" -Direction Inbound -Protocol TCP -LocalPort 5985 -RemoteAddress <IP_POSTE_ADMIN> -Action Allow -Profile Any
```

- Sur le poste d'administration, en administrateur (environnement hors domaine) :

```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "<IP_POSTE1>,<IP_POSTE2>" -Force
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Utilisation

Toutes les commandes se lancent depuis la racine du projet.

**1. Renseigner l'inventaire** dans `Config\computers.txt`, au format `NOM;ADRESSE_IP` :

```
PC01;192.168.93.11
PC02;192.168.93.13
```

**2. Enregistrer les identifiants une seule fois** (mot de passe chiffré par DPAPI, lisible uniquement par l'utilisateur courant sur ce poste) :

```powershell
.\Scripts\Commun\Initialize-Credentials.ps1
```

**3. Lancer les scripts :**

| Script | Rôle | Fichiers produits |
| --- | --- | --- |
| `Scripts\Partie1\Partie1-Disponibilite.ps1` | État de disponibilité des postes | — |
| `Scripts\Partie2\Partie2-Inventaire.ps1` | Inventaire système du parc | `Rapports\Inventaire.csv` |
| `Scripts\Partie3\Partie3-Correctifs.ps1` | Inventaire des correctifs | `Rapports\PatchesInventory.csv`, `Rapports\PatchesSummary.csv` |

Si Windows bloque les scripts téléchargés : `Get-ChildItem -Recurse -Filter *.ps*1 | Unblock-File`.

## Sécurité

- Aucun mot de passe en clair dans les scripts : les identifiants sont stockés chiffrés dans `credentials\`, exclu du dépôt par `.gitignore`.
- WinRM n'est autorisé que depuis le poste d'administration (règle de pare-feu restreinte).
- `TrustedHosts` ne liste que les postes du parc, jamais `*`.

## Auteur

Adrien Rivet – EFREI, S7
