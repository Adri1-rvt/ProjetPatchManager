# Rapport – Système de gestion des mises à jour en PowerShell

Oct 7, 2026 · @Adrien

## Introduction

Ce projet met en place une solution simplifiée de Patch Management pour un parc Windows, entièrement pilotée en PowerShell depuis un poste d'administration central.

Projet réalisé en binôme par **Adrien Rivet** et **Alexandre Brenski**, dans le cadre du module Sécurité des systèmes (EFREI, S7).

Un poste auquel il manque des correctifs de sécurité constitue un point d'entrée pour un attaquant, et peut servir de rebond vers le reste du réseau. Contrôler l'état des mises à jour poste par poste devient vite inefficace : la solution automatise ces contrôles grâce à PowerShell Remoting (WinRM).

La chaîne visée est la suivante :

1. Inventaire des postes à partir du fichier `computers.txt`.
2. Connexion distante par PowerShell Remoting.
3. Collecte des correctifs installés.
4. Contrôle de conformité par rapport à une liste de correctifs obligatoires.
5. Détection des anomalies (postes non conformes ou inaccessibles).
6. Production d'un rapport (CSV et HTML) et notification de l'administrateur.

Ce document est rédigé au fil de l'avancement du projet. Le code source est versionné dans le dépôt GitHub privé [Adri1-rvt/ProjetPatchManager](https://github.com/Adri1-rvt/ProjetPatchManager).

## Architecture de l'environnement de test

L'environnement comprend trois machines Windows : l'hôte physique, qui sert de poste d'administration, et deux machines virtuelles Windows 11 Professionnel, qui jouent le rôle des postes supervisés.

Les VM sont hébergées sous VMware Workstation et disposent chacune de deux cartes réseau :

- **Carte 1 – NAT (VMnet8, 192.168.244.0/24)** : accès Internet, indispensable pour que Windows Update installe des correctifs à inventorier.
- **Carte 2 – Host-only (VMnet1, 192.168.93.0/24)** : réseau privé entre l'hôte et les VM, utilisé pour l'administration distante (ping, WinRM).

&#91;embedded content: architecture réseau · hôte, 2 VM, 1 poste fictif\]

WinRM ne circule que sur le réseau host-only ; la carte NAT sert uniquement à l'accès Internet des VM pour Windows Update.

Le réseau VMnet1 n'a pas de serveur DHCP. Les adresses sont donc fixées manuellement, ce qui garantit des IP stables pour l'inventaire `computers.txt`.

| Machine | Rôle | Système | IP sur VMnet1 |
| --- | --- | --- | --- |
| PC\_ADRI1 | Poste d'administration (hôte) | Windows (hôte physique) | 192.168.93.1 |
| PC01 | Poste supervisé (VM) | Windows 11 Professionnel | 192.168.93.11 |
| PC02 | Poste supervisé (VM, clone de PC01) | Windows 11 Professionnel | 192.168.93.13 |
| PC03 | Poste fictif, volontairement inexistant | — | 192.168.93.20 |

Le poste PC03 n'existe pas : il figure dans l'inventaire pour démontrer la gestion des machines inaccessibles.

## Mise en place des machines virtuelles

PC01 a été installée manuellement, puis PC02 a été obtenue par clonage complet de PC01, ce qui a divisé le temps de préparation par deux.

**Installation de PC01**

1. Création de la VM sous VMware Workstation : 4 Go de RAM, 2 vCPU, disque de 64 Go, firmware EFI (requis par Windows 11).
2. Installation de **Windows 11 Professionnel**. L'édition Famille a été écartée car elle ne permet pas d'utiliser WinRM comme serveur de remoting.
3. Création d'un compte local `admin` protégé par mot de passe (option « Joindre un domaine à la place »). Un mot de passe est obligatoire : PowerShell Remoting refuse les comptes sans mot de passe.
4. Renommage du poste :

```powershell
Rename-Computer -NewName "PC01" -Restart
```

5. Configuration de la carte host-only avec une IP fixe, sans passerelle, pour ne pas concurrencer la route Internet de la carte NAT :

```powershell
New-NetIPAddress -InterfaceAlias "Ethernet1" -IPAddress 192.168.93.11 -PrefixLength 24
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
Get-NetFirewallRule -Name "FPS-ICMP4-ERQ-In*" | Enable-NetFirewallRule
```

La règle de pare-feu est désignée par son nom interne (`FPS-ICMP4-ERQ-In`) plutôt que par son nom affiché, qui dépend de la langue de Windows.

**Création de PC02**

Un snapshot de PC01 a d'abord été pris, puis la VM a été clonée (clone complet, avec de nouvelles adresses MAC générées par VMware). Le clone héritant de l'IP fixe de PC01, il a été démarré seul pour éviter un conflit d'adresse, puis reconfiguré :

```powershell
Remove-NetIPAddress -InterfaceAlias "Ethernet1" -IPAddress 192.168.93.11 -Confirm:$false
New-NetIPAddress -InterfaceAlias "Ethernet1" -IPAddress 192.168.93.13 -PrefixLength 24
Rename-Computer -NewName "PC02" -Restart
```

## Partie 1 – Connectivité, inventaire et disponibilité

Les deux VM répondent au ping depuis l'hôte, et le script de disponibilité classe correctement PC01 et PC02 comme accessibles et PC03 comme inaccessible.

**Point 1 – Vérification de la connectivité**

Depuis l'hôte, `Test-Connection` a été utilisé sur chaque VM :

```powershell
Test-Connection 192.168.93.11 -Count 1
Test-Connection 192.168.93.13 -Count 1
```

Les deux machines répondent en moins de 5 ms. Le ping dans le sens VM vers hôte n'a pas été ouvert : seul l'hôte a besoin d'interroger les postes.

**Point 2 – Fichier `computers.txt`**

L'inventaire suit le format `NOM;ADRESSE_IP`. Les lignes vides et les lignes commençant par `#` sont ignorées, ce qui permet de commenter le fichier ou de désactiver temporairement un poste.

```
# Inventaire du parc - format : NOM;ADRESSE_IP
PC01;192.168.93.11
PC02;192.168.93.13
# Poste volontairement inexistant : sert à tester le cas "Inaccessible"
PC03;192.168.93.20
```

**Point 3 – Script `Partie1-Disponibilite.ps1`**

Le script lit `computers.txt`, teste chaque poste par ping et affiche son nom, son adresse IP et son état. Il est découpé en deux fonctions réutilisables dans les parties suivantes :

- `Get-ComputerInventory` lit et valide le fichier, et signale les lignes mal formées par un avertissement au lieu d'interrompre le script.
- `Test-ComputerAvailability` teste un poste avec `Test-Connection -Quiet` et renvoie un objet PowerShell (`Poste`, `Adresse IP`, `Etat`).

Le script affiche un résultat coloré pour l'administrateur et renvoie aussi les objets, exploitables par un autre script (`$etat = .\Partie1-Disponibilite.ps1`). Le chemin de l'inventaire est résolu par rapport au dossier du script (`$PSScriptRoot`), ce qui le rend indépendant du dossier courant.

Résultat obtenu :

| Poste | Adresse IP | État |
| --- | --- | --- |
| PC01 | 192.168.93.11 | Accessible |
| PC02 | 192.168.93.13 | Accessible |
| PC03 | 192.168.93.20 | Inaccessible |

Le poste inaccessible ne bloque pas l'exécution : il est simplement signalé après expiration du délai du ping.

## Partie 1 – Activation de PowerShell Remoting (point 4)

PowerShell Remoting est opérationnel sur PC01 et PC02 : `Test-WSMan` répond depuis l'hôte pour les deux VM.

**Sur chaque VM**

```powershell
Enable-PSRemoting -Force
Get-Service WinRM
```

`Enable-PSRemoting` réalise en une seule commande :

| Action | Effet |
| --- | --- |
| Création d'un écouteur HTTP | WinRM écoute sur le port TCP 5985 |
| Démarrage du service WinRM | Service en démarrage automatique, état Running |
| Exception de pare-feu WinRM | Règle entrante pour les profils Domaine et Privé |
| `LocalAccountTokenFilterPolicy` | Les administrateurs locaux conservent leurs droits complets à distance |

**Sur l'hôte**

Les machines ne sont pas membres d'un domaine Active Directory : Kerberos n'est pas disponible et l'authentification se fait en NTLM. Le client WinRM de l'hôte doit donc faire explicitement confiance aux VM via la liste TrustedHosts :

```powershell
Start-Service WinRM
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.93.11,192.168.93.13" -Force
Test-WSMan 192.168.93.11
Test-WSMan 192.168.93.13
```

Seules les deux adresses des VM sont listées. La valeur `*` aurait fonctionné aussi, mais elle autoriserait l'envoi d'identifiants vers n'importe quelle machine.

**Règle de pare-feu restreinte**

Une règle explicite a été ajoutée sur chaque VM pour n'autoriser WinRM que depuis le poste d'administration, quel que soit le profil réseau (la raison est détaillée dans la section Problèmes rencontrés) :

```powershell
New-NetFirewallRule -DisplayName "WinRM - Poste admin uniquement" -Direction Inbound -Protocol TCP -LocalPort 5985 -RemoteAddress 192.168.93.1 -Action Allow -Profile Any
```

Un snapshot « WinRM OK » a ensuite été pris sur les deux VM, pour pouvoir revenir à un état fonctionnel si une manipulation ultérieure casse l'accès distant.

## Partie 1 – Session interactive avec Enter-PSSession (point 5)

Une session interactive a été ouverte depuis l'hôte sur PC01 : l'invite devient `[192.168.93.11]: PS C:\Users\admin\Documents>`, preuve que les commandes s'exécutent sur la machine distante.

```powershell
$cred = Get-Credential PC01\admin
Enter-PSSession -ComputerName 192.168.93.11 -Credential $cred
hostname                              # PC01
whoami                                # pc01\admin
Get-Service wuauserv                  # Stopped
Get-HotFix | Select-Object -First 5
Exit-PSSession
```

Hors domaine, le compte est désigné sous la forme `NOMDUPOSTE\utilisateur`. Le mot de passe saisi via `Get-Credential` est conservé chiffré dans la variable `$cred`.

Deux observations utiles pour la suite du projet :

- **Le service Windows Update (`wuauserv`) est arrêté.** C'est son comportement normal : il est en démarrage manuel et ne tourne que lorsqu'une recherche ou une installation de mises à jour est en cours. Un état `Stopped` n'est donc pas une anomalie ; seul un type de démarrage `Disabled` en serait une. L'inventaire de la Partie 2 relèvera les deux informations.
- **`Get-HotFix` renseigne mal certains champs.** Le compte d'installation (`InstalledBy`) est souvent vide, et la date d'installation n'a pas d'heure. Ces limites viennent de la classe WMI `Win32_QuickFixEngineering` sur laquelle repose la commande.

## Partie 1 – Exécution non interactive avec Invoke-Command (point 6)

Le script `Partie1-InvokeCommand.ps1` exécute le même bloc de commandes en parallèle sur PC01 et PC02 et récupère les résultats sous forme d'objets PowerShell.

Contrairement à `Enter-PSSession`, destinée à un administrateur qui tape des commandes, `Invoke-Command` est scriptable : c'est la commande qui servira de base à toutes les parties suivantes.

Le script procède en trois temps :

1. Saisie des identifiants de chaque poste avec `Get-Credential` (comptes locaux distincts : `PC01\admin` et `PC02\admin`).
2. Ouverture d'une session persistante par poste avec `New-PSSession`.
3. Exécution parallèle avec `Invoke-Command -Session $s1, $s2`, puis fermeture des sessions dans un bloc `finally`, ce qui garantit leur fermeture même en cas d'erreur.

Résultat obtenu :

| Poste | Correctifs installés | Windows Update | PSComputerName |
| --- | --- | --- | --- |
| PC01 | 5 | Running | 192.168.93.11 |
| PC02 | 5 | Running | 192.168.93.13 |

PowerShell ajoute automatiquement la propriété `PSComputerName`, qui indique de quel poste provient chaque objet. Le service Windows Update est cette fois `Running`, alors qu'il était `Stopped` quelques minutes plus tôt : cela confirme qu'il démarre à la demande.

## Partie 1 – Réponses aux questions

**Quel est le rôle de WinRM dans PowerShell Remoting ?**

WinRM (Windows Remote Management) est l'implémentation Microsoft du protocole standard WS-Management, qui transporte des messages SOAP sur HTTP ou HTTPS. C'est la couche de transport de PowerShell Remoting : le service WinRM écoute les requêtes, authentifie l'utilisateur, puis transmet les commandes au point de terminaison PowerShell de la machine distante. Les résultats reviennent sérialisés sous forme d'objets.

**Quelle commande permet d'activer PowerShell Remoting ?**

`Enable-PSRemoting -Force`, exécutée en administrateur. Elle démarre le service WinRM, crée l'écouteur, ouvre le pare-feu et enregistre les points de terminaison PowerShell. Dans un parc en domaine, on l'appliquerait plutôt par stratégie de groupe (GPO).

**Quels ports réseau sont utilisés par WinRM ?**

TCP 5985 pour HTTP et TCP 5986 pour HTTPS.

**Pourquoi le pare-feu Windows peut-il empêcher une connexion PowerShell distante ?**

Le pare-feu bloque toute connexion entrante qu'aucune règle n'autorise. Sur Windows client, la règle WinRM créée par `Enable-PSRemoting` ne couvre que les profils Domaine et Privé. Une carte réseau en profil Public laisse donc le port 5985 fermé. Ce cas s'est produit dans ce projet : le ping passait, mais WinRM était bloqué.

**Quelle différence entre Test-Connection et Test-WSMan ?**

`Test-Connection` envoie un ping ICMP et vérifie seulement que la machine est joignable sur le réseau. `Test-WSMan` envoie une requête WS-Management sur le port 5985 et vérifie que le service WinRM répond réellement. Une machine peut répondre au ping tout en restant inaccessible pour PowerShell Remoting, et inversement si l'ICMP est bloqué.

**Pourquoi vérifier l'accessibilité avant une commande distante ?**

- Une tentative de connexion vers une machine éteinte attend l'expiration d'un délai de plusieurs secondes : sur un grand parc, ces attentes s'accumulent.
- Le script peut distinguer clairement un poste inaccessible d'une commande qui échoue, et enregistrer la cause exacte dans le rapport.
- Les erreurs restent contrôlées : l'audit continue sur les autres postes au lieu de s'interrompre.

**Quels risques si PowerShell Remoting est activé sans restriction ?**

- **Mouvement latéral** : un attaquant qui obtient des identifiants administrateur peut exécuter du code sur toutes les machines du parc.
- **Attaques sur les identifiants** : un port 5985 ouvert à tout le réseau expose les comptes au brute-force et, en NTLM, au pass-the-hash.
- **TrustedHosts = `*`** : le poste d'administration enverrait ses identifiants à n'importe quelle machine, y compris une machine piégée.
- **Droits excessifs** : sans restriction (JEA), toute session distante dispose de l'ensemble des commandes PowerShell.
- **Traçabilité insuffisante** : sans journalisation PowerShell activée (Script Block Logging, transcription), les actions menées à distance laissent peu de traces.

Les mesures correspondantes sont déjà en partie appliquées (règle de pare-feu limitée au poste d'administration, TrustedHosts restreint) et seront approfondies en Partie 8.

## Organisation du code

Le projet sépare la configuration, le code, les identifiants et les résultats dans des dossiers distincts, et un seul fichier connaît cette organisation.

```
ProjetPatchManager\
├── Config\            computers.txt, required-patches.txt, notification.json
├── credentials\       identifiants chiffrés : <NOM>.xml (svc_patch), <NOM>.admin.xml (admin), smtp.xml
├── Rapports\          CSV, rapports HTML, journal PatchManager.log
│   └── Historique\    copies horodatées des rapports HTML
├── Screenshots\       captures par partie
├── Scripts\
│   ├── Commun\        PatchManager.psm1, Initialize-Credentials.ps1, Initialize-MailCredential.ps1
│   ├── Partie1\       Partie1-Disponibilite.ps1, Partie1-InvokeCommand.ps1
│   ├── Partie2\       Partie2-Inventaire.ps1
│   ├── Partie3\       Partie3-Correctifs.ps1
│   ├── Partie4\       Partie4-Conformite.ps1
│   ├── Partie6\       Partie6-RapportSecurite.ps1
│   ├── Partie7\       Partie7-Notification.ps1
│   └── Partie8\       Partie8-AuditSecurite.ps1, Partie8-Durcissement.ps1, Partie8-InstallJEA.ps1, Diagnostic-JEA.ps1
└── README.md
```

Le module commun `PatchManager.psm1` expose la fonction `Get-ProjectPaths`, qui calcule tous les chemins du projet à partir de l'emplacement du module lui-même. Les scripts ne contiennent donc aucun chemin écrit en dur : ils chargent le module avec un chemin relatif (`..\Commun\PatchManager.psm1`), puis lui demandent où se trouvent l'inventaire, les identifiants et le dossier des rapports. Une réorganisation future ne demanderait de modifier qu'un seul fichier.

Le chargement du module utilise `-ErrorAction Stop` : si le module est introuvable, le script s'arrête immédiatement avec un message explicite au lieu de poursuivre avec des fonctions restées en mémoire d'une exécution précédente.

## Partie 2 – Inventaire du parc

Le script `Partie2-Inventaire.ps1` collecte les caractéristiques système et les informations de mise à jour de chaque poste accessible, et exporte le résultat dans `Rapports\Inventaire.csv`.

**Fondations communes**

Avant l'inventaire, deux éléments réutilisables ont été créés :

- **Le module `PatchManager.psm1`** regroupe les fonctions partagées par tous les scripts : lecture de l'inventaire (`Get-ComputerInventory`), test d'accessibilité (`Test-ComputerAvailability`) et chargement des identifiants (`Get-StoredCredential`). Le test d'accessibilité vérifie désormais le ping puis WinRM, et indique la cause d'un échec (« Ping sans réponse » ou « WinRM inaccessible »).
- **Le script `Initialize-Credentials.ps1`** enregistre une seule fois les identifiants de chaque poste dans `credentials\<NOM>.xml` avec `Export-Clixml`. Le mot de passe y est chiffré par DPAPI : seul le même utilisateur Windows, sur le même poste, peut le déchiffrer. Le dossier `credentials` est exclu du dépôt Git par le fichier `.gitignore`.

**Informations collectées**

Chaque poste est interrogé en une seule connexion `Invoke-Command`. Le bloc exécuté à distance s'appuie sur les classes CIM de Windows :

| Information | Source sur le poste |
| --- | --- |
| Nom, fabricant, modèle, RAM | `Win32_ComputerSystem` |
| Version du BIOS | `Win32_BIOS` |
| Édition, architecture, dernier démarrage | `Win32_OperatingSystem` |
| Version de Windows (ex. 26H2) | Registre `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion` |
| Espace libre du disque système | `Win32_LogicalDisk` |
| Nombre de mises à jour, date et KB de la dernière | `Get-HotFix` |
| État et type de démarrage de Windows Update | `Get-Service wuauserv` |

**Gestion des erreurs**

Chaque poste est traité dans un bloc `try/catch`. Un poste inaccessible, des identifiants absents ou une collecte qui échoue ne bloquent jamais les autres postes. La cause est enregistrée dans la colonne `Erreur` de l'inventaire, et l'état du poste prend la valeur `Inaccessible` ou `Erreur`. Tous les postes partagent la même structure d'objet, ce qui garantit des colonnes identiques dans le CSV.

**Résultat obtenu**

| Poste | Adresse IP | Windows | Architecture | RAM | Disque libre | Mises à jour | Dernière KB | Windows Update | État |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| PC01 | 192.168.93.11 | Windows 11 Professionnel 26H2 | 64 bits | 6,1 Go | 26,2 / 48,9 Go | 5 | KB5128942 | Stopped (Manual) | Accessible |
| PC02 | 192.168.93.13 | Windows 11 Professionnel 26H2 | 64 bits | 6,1 Go | 26,2 / 48,9 Go | 5 | KB5128942 | Stopped (Manual) | Accessible |
| PC03 | 192.168.93.20 | — | — | — | — | — | — | — | Inaccessible (ping sans réponse) |

Le CSV utilise le séparateur `;` et l'encodage UTF-8 avec BOM, pour s'ouvrir directement en colonnes et avec les accents corrects dans Excel en français. PC01 et PC02 ont des caractéristiques identiques, ce qui est attendu puisque PC02 est un clone de PC01.

## Partie 3 – Inventaire des correctifs

Le script `Partie3-Correctifs.ps1` recense les correctifs des postes accessibles et produit `Rapports\PatchesInventory.csv`, trié par poste puis par date d'installation décroissante.

**Points 1 et 2 – Correctifs de la machine locale**

Le script commence par lister les correctifs du poste d'administration avec `Get-HotFix`, en retenant le numéro de KB, la description, la date d'installation et le compte d'installation :

| KB | Description | Date d'installation | Installé par |
| --- | --- | --- | --- |
| KB5129195 | Security Update | 18/09/2026 | AUTORITE NT\\Système |
| KB5124007 | Security Update | 09/09/2026 | AUTORITE NT\\Système |
| KB5126052 | Update | 09/09/2026 | AUTORITE NT\\Système |
| KB5054156 | Update | 29/01/2026 | AUTORITE NT\\Système |

Le compte d'installation n'est pas toujours renseigné par `Get-HotFix` (classe WMI `Win32_QuickFixEngineering`). Quand il manque, le script affiche « Non disponible ».

**Points 3 à 5 – Collecte à distance**

Le même bloc de collecte est exécuté sur chaque poste avec `Invoke-Command`. Les postes inaccessibles sont ignorés proprement : leur cause est conservée dans la synthèse, et l'exécution continue. Chaque correctif devient une ligne Poste / Adresse IP / KB / Description / Date d'installation / Installé par.

**Point 6 – Regroupement et synthèse**

Les correctifs de tous les postes sont regroupés, triés par poste puis par date décroissante, et exportés dans `Rapports\PatchesInventory.csv`. Le script affiche ensuite une synthèse par poste, également exportée dans `Rapports\PatchesSummary.csv` pour être réutilisée par le rapport final :

| Poste | Correctifs recensés | Correctif le plus récent | Dernière KB | État |
| --- | --- | --- | --- | --- |
| PC01 | 5 | 07/10/2026 | KB5128942 | Accessible |
| PC02 | 5 | 07/10/2026 | KB5128942 | Accessible |
| PC03 | — | — | — | Inaccessible |

Les deux VM portent les mêmes correctifs : KB5121794, KB5124007, KB5126052 et KB5129195 installés le 13/09/2026, puis KB5128942 installé le 07/10/2026. Le poste d'administration n'a pas le même niveau de correctifs, ce qui illustre l'intérêt d'un contrôle de conformité centralisé (Partie 4).

## Partie 4 – Contrôle de conformité

Le script `Partie4-Conformite.ps1` compare les correctifs installés sur chaque poste avec une liste de correctifs obligatoires, attribue un état à chaque poste et calcule le taux de conformité du parc.

**Points 1 et 2 – Politique de correctifs**

La politique est définie dans `Config\required-patches.txt`, à raison d'un numéro de KB par ligne, avec des commentaires possibles après `#` :

```
KB5124007   # Security Update
KB5129195   # Security Update
KB5128942   # Mise à jour du 07/10/2026
```

La fonction `Get-RequiredPatches` du module lit cette liste, met les numéros en majuscules, supprime les doublons et ignore avec un avertissement toute ligne qui n'est pas un numéro de KB valide. Une faute de frappe dans la politique ne peut donc pas fausser silencieusement le contrôle.

**Points 3 et 4 – État de chaque poste**

Pour chaque poste accessible, le script récupère la liste des KB installées puis calcule les KB obligatoires absentes. Le poste reçoit l'un des trois états suivants :

| État | Condition |
| --- | --- |
| CONFORME | Tous les correctifs obligatoires sont installés |
| NON CONFORME | Au moins un correctif obligatoire manque |
| INACCESSIBLE | Le poste n'a pas pu être contrôlé (ping, WinRM, identifiants ou collecte en échec) |

Pour chaque poste non conforme, le script affiche la liste précise des KB manquantes, avec la date et l'heure du contrôle.

**Points 5 et 6 – Enregistrement et taux de conformité**

Les résultats sont enregistrés dans `Rapports\ComplianceReport.csv` (Poste, Adresse IP, KB requises, KB manquantes, liste des KB manquantes, État, Détail, Date du contrôle). Le taux de conformité est calculé sur les seuls postes contrôlés :

```latex
\text{Taux} = \frac{\text{postes conformes}}{\text{postes conformes} + \text{postes non conformes}} \times 100
```

Les postes inaccessibles sont exclus du calcul : leur état réel est inconnu, et les compter comme conformes ou non conformes fausserait le résultat. Ils restent signalés séparément.

**Résultats obtenus**

Deux contrôles ont été réalisés pour démontrer les deux cas :

| Scénario | PC01 | PC02 | PC03 | Taux |
| --- | --- | --- | --- | --- |
| Politique initiale (3 KB) | CONFORME | CONFORME | INACCESSIBLE | 100 % |
| Ajout de KB5054156 à la politique (4 KB) | NON CONFORME (KB5054156 manquante) | NON CONFORME (KB5054156 manquante) | INACCESSIBLE | 0 % |

Le second scénario simule la publication d'un nouveau correctif obligatoire : sans aucun changement sur les postes, l'ajout d'une seule ligne à la politique fait basculer tout le parc en non-conformité.

**Point 7 – Pourquoi la politique de conformité doit-elle être régulièrement mise à jour ?**

- **De nouvelles vulnérabilités sont publiées en continu.** Microsoft publie ses correctifs chaque mois (le « Patch Tuesday »), plus des correctifs d'urgence pour les failles activement exploitées. Une liste figée déclarerait conforme un poste vulnérable aux failles plus récentes, ce qui donne un faux sentiment de sécurité.
- **Les mises à jour cumulatives se remplacent.** Chaque mise à jour cumulative mensuelle intègre et remplace les précédentes, dont la KB peut disparaître de la liste des correctifs installés. Exiger une ancienne KB remplacée déclarerait non conforme un poste pourtant à jour.
- **Les KB dépendent de la version de Windows.** Un même correctif porte des numéros différents selon la version (Windows 10, Windows 11 24H2, 26H2…). La politique doit suivre l'évolution du parc.
- **Les versions en fin de support ne reçoivent plus de correctifs.** Un poste peut n'avoir « aucune KB manquante » simplement parce que Microsoft ne publie plus rien pour sa version : la politique doit alors signaler le système lui-même comme non conforme.

Ce contrôle par numéros de KB reste donc une approche simplifiée. En production, on s'appuierait plutôt sur des outils qui connaissent les relations de remplacement entre correctifs, comme WSUS, Microsoft Intune ou Configuration Manager.

## Partie 6 – Rapport de sécurité

Le script `Partie6-RapportSecurite.ps1` audite tout le parc en une seule passe et produit un rapport CSV, un rapport HTML, une archive horodatée du rapport HTML et le journal des exécutions.

**Un audit en une seule passe**

Le rapport ne relit pas les fichiers CSV des parties précédentes : il réalise un nouvel audit complet, avec une seule connexion `Invoke-Command` par poste. Toutes les informations du rapport datent ainsi du même contrôle. Assembler des CSV produits à des moments différents pourrait au contraire donner une image incohérente, par exemple un poste conforme dans un fichier et non conforme dans un autre.

**Point 1 – Rapport par poste**

Pour chaque poste, le rapport contient le nom, l'adresse IP, l'état d'accessibilité, la version de Windows, la date du dernier démarrage, l'état et le type de démarrage du service Windows Update, le nombre de correctifs requis et manquants, la liste des KB manquantes, l'état de conformité et la date et l'heure du contrôle. Il est enregistré dans `Rapports\SecurityReport.csv`.

**Point 2 – Synthèse globale et postes nécessitant une intervention**

La synthèse reprend les sept indicateurs demandés. Une section distincte liste les postes nécessitant une intervention, avec le motif. Trois motifs sont détectés :

- un ou plusieurs correctifs obligatoires manquants ;
- un poste injoignable, avec la cause (ping sans réponse, WinRM inaccessible, identifiants absents ou collecte en échec) ;
- un service Windows Update **désactivé**. Un tel poste peut être conforme au moment du contrôle, mais il ne recevra plus aucun correctif : il deviendra non conforme à la prochaine mise à jour de la politique.

**Point 3 – Version HTML**

Le rapport HTML est une page autonome, sans dépendance externe, qui s'ouvre dans n'importe quel navigateur. Il présente les indicateurs de la synthèse, une barre de conformité colorée, la liste des postes nécessitant une intervention, le détail par poste avec des badges de couleur (vert pour conforme, orange pour non conforme, rouge pour inaccessible) et la politique de correctifs appliquée. Toutes les valeurs sont encodées avec `HtmlEncode` avant d'être insérées dans la page, pour qu'une donnée collectée sur un poste ne puisse pas injecter de code dans le rapport.

Chaque exécution conserve aussi une copie horodatée dans `Rapports\Historique\`, ce qui permet de suivre l'évolution de la conformité dans le temps.

**Point 4 – Journal des exécutions**

La fonction `Write-PatchLog` du module ajoute chaque étape de l'audit au fichier `Rapports\PatchManager.log`, au format demandé :

```
07/10/2026 19:06:50 ; Début de l'audit
07/10/2026 19:06:50 ; PC01 ; Accessible
07/10/2026 19:06:51 ; PC01 ; Conforme
07/10/2026 19:06:51 ; PC02 ; Accessible
07/10/2026 19:06:52 ; PC02 ; Conforme
07/10/2026 19:06:56 ; PC03 ; Ping sans réponse
07/10/2026 19:06:56 ; Rapport généré
07/10/2026 19:06:56 ; Fin de l'audit
```

Une erreur d'écriture dans le journal est signalée mais n'interrompt jamais l'audit.

**Résultat obtenu**

L'audit du 07/10/2026 à 19:06:50 donne 3 postes, dont 2 accessibles et conformes et 1 inaccessible, pour un taux de conformité de 100 %. Seul PC03 nécessite une intervention (ping sans réponse).

Avant d'être exécuté sur le parc, le script a été testé dans un environnement simulé contenant un poste conforme, un poste non conforme avec Windows Update désactivé et un poste inaccessible : le taux calculé était de 50 %, et les deux motifs d'intervention de PC02 apparaissaient correctement.

## Partie 7 – Notification

Le script `Partie7-Notification.ps1` envoie un e-mail à l'administrateur uniquement si au moins un poste est NON CONFORME ou INACCESSIBLE, avec le rapport de sécurité en pièces jointes.

**Point 1 – Détection des anomalies et construction du message**

Le script lit le rapport produit par la Partie 6 (`Rapports\SecurityReport.csv`). L'option `-RunAudit` relance d'abord un audit complet, pour notifier sur des données fraîches ; sans elle, un avertissement s'affiche si le rapport a plus de 24 heures.

- **Aucune anomalie** : le script se termine sans rien envoyer, et le journal l'indique.
- **Au moins une anomalie** : le message est construit au format demandé, puis envoyé avec le rapport HTML et le rapport CSV en pièces jointes.

```
Objet : [PATCH MANAGEMENT] Anomalies détectées

Date du contrôle : 07/10/2026

Postes contrôlés      : 3
Postes non conformes  : 2
Postes inaccessibles  : 1

PC01 : NON CONFORME
        KB5054156 manquante

PC02 : NON CONFORME
        KB5054156 manquante

PC03 : INACCESSIBLE (Ping sans réponse)
```

L'option `-DryRun` construit et affiche le message sans l'envoyer : elle a permis de valider le contenu avant de configurer le compte e-mail.

**Protection du mot de passe de messagerie**

Aucune information sensible n'est écrite dans le script. Les paramètres d'envoi (serveur SMTP, port, expéditeur, destinataires) sont dans `Config\notification.json`, qui ne contient aucun mot de passe. Le mot de passe est un **mot de passe d'application**, jamais le mot de passe principal du compte. Il est enregistré une seule fois par `Initialize-MailCredential.ps1` dans `credentials\smtp.xml`, chiffré par DPAPI comme les autres identifiants, et ce dossier est exclu du dépôt Git.

L'envoi force TLS 1.2 : Windows PowerShell 5.1 peut sinon négocier un protocole plus ancien, refusé par les fournisseurs de messagerie actuels.

**Traçabilité**

Chaque exécution laisse une trace dans `Rapports\PatchManager.log` :

```
07/10/2026 19:45:12 ; Notification envoyée à admin@exemple.com
07/10/2026 19:47:03 ; ERREUR ; Notification non envoyée ; <cause de l'échec>
07/10/2026 19:48:30 ; Aucune anomalie ; notification non nécessaire
```

En cas d'échec, la cause est ajoutée à la ligne d'erreur pour faciliter le diagnostic, et le script renvoie le code de sortie 2. Une tâche planifiée peut ainsi détecter qu'une alerte n'est pas partie.

**Tests réalisés**

| Scénario | Résultat attendu | Résultat obtenu |
| --- | --- | --- |
| Anomalies, mode `-DryRun` | Message affiché, rien envoyé | Conforme |
| Anomalies, envoi réel | E-mail reçu avec le rapport HTML et le CSV, envoi tracé | Conforme |
| Aucune anomalie (PC03 retiré, politique initiale) | Aucun envoi, ligne « Aucune anomalie » dans le journal | Conforme |
| Échec d'envoi (test en environnement simulé) | Ligne d'erreur dans le journal, code de sortie 2 | Conforme |

**Point 2 – Quels sont les inconvénients de cette solution ?**

- **Commande obsolète** : Microsoft a déclaré `Send-MailMessage` obsolète, car elle ne garantit pas une connexion sécurisée et ne prend pas en charge l'authentification moderne (OAuth 2.0).
- **Secret de forte valeur** : un mot de passe d'application contourne l'authentification à deux facteurs et donne accès à toute la boîte mail. Il doit être stocké sur le poste d'administration, et le chiffrement DPAPI le lie à un utilisateur et un poste : une tâche planifiée doit tourner sous ce même compte.
- **Fuite d'informations sensibles** : le message et le rapport joint listent les postes vulnérables et les correctifs manquants. Ces informations transitent et restent stockées chez un fournisseur de messagerie externe, ce qui peut aider un attaquant.
- **Remise non garantie** : le port SMTP sortant peut être bloqué, le message peut finir en courrier indésirable, et les fournisseurs grand public limitent le volume d'envoi.
- **Aucun suivi** : un e-mail ne crée ni ticket, ni accusé de lecture, ni escalade. Des alertes répétées finissent par être ignorées.
- **Silence ambigu** : l'absence d'e-mail peut signifier « aucune anomalie » comme « le script n'a pas tourné », par exemple si le poste d'administration est éteint.

**Point 3 – Quelles alternatives modernes à un simple envoi SMTP ?**

- **Microsoft Graph API** : envoi via l'API Graph avec une application enregistrée dans Microsoft Entra ID et une authentification OAuth 2.0 par certificat. C'est le remplaçant recommandé par Microsoft, sans mot de passe stocké.
- **Relais SMTP interne** : un connecteur Exchange de l'entreprise, autorisé par adresse IP, évite tout mot de passe et garde les messages à l'intérieur du système d'information.
- **Messagerie d'équipe** : une publication dans un canal Teams ou Slack par webhook (`Invoke-RestMethod`), visible par toute l'équipe d'exploitation.
- **Outil de ticketing** : création automatique d'un ticket (GLPI, ServiceNow…), avec un responsable, un suivi et une clôture.
- **Supervision et SIEM** : écriture des anomalies dans le journal d'événements Windows, collecté par un SIEM (Microsoft Sentinel, Splunk, Wazuh) ou un outil de supervision (Zabbix, Nagios), qui gère les règles d'alerte et détecte aussi l'absence d'exécution.
- **Coffre de secrets** : si un secret reste nécessaire, le stocker dans un coffre (module PowerShell SecretManagement, Azure Key Vault) plutôt que dans un fichier local.
- **Solutions de gestion des correctifs** : WSUS, Microsoft Intune, Configuration Manager ou Azure Update Manager intègrent nativement le suivi de conformité et les alertes.

## Partie 8 – Sécurisation de la solution

Un audit automatisé a mesuré l'état de sécurité avant et après durcissement : on passe de 2 risques et 6 points d'attention à 0 risque et 1 point d'attention conservé volontairement, tout en continuant à auditer le parc avec un compte non administrateur.

Quatre scripts composent cette partie :

| Script | Rôle |
| --- | --- |
| `Partie8-AuditSecurite.ps1` | Contrôle automatique de la configuration (points 2 à 7), chaque constat classé OK, INFO, ATTENTION ou RISQUE |
| `Partie8-Durcissement.ps1` | Compte de service non administrateur, pare-feu, journalisation PowerShell |
| `Partie8-InstallJEA.ps1` | Point de terminaison JEA réservé au compte de service |
| `Diagnostic-JEA.ps1` | Diagnostic détaillé du point de terminaison JEA, sans modification |

| Contrôle | Avant | Après |
| --- | --- | --- |
| Compte utilisé par le Patch Management | `admin`, administrateur | `svc_patch`, non administrateur, via JEA |
| Pare-feu WinRM | Règle par défaut ouverte à toute adresse (RISQUE) | Seul 192.168.93.1 autorisé |
| Journalisation PowerShell | Désactivée | Script Block Logging activé + transcription des sessions JEA |
| Point de terminaison JEA | Absent | Présent, réservé à `svc_patch` |
| LocalAccountTokenFilterPolicy | 1 | 1, conservé volontairement (voir point 3) |
| Bilan de l'audit | 2 risques, 6 points d'attention | 0 risque, 2 points d'attention (le même réglage sur les deux VM) |

**Point 1 – Principaux risques liés à PowerShell Remoting / WinRM**

- **Mouvement latéral** : un attaquant qui obtient des identifiants d'administration peut exécuter du code sur tous les postes du parc depuis une seule machine.
- **Vol et rejeu d'identifiants** : hors domaine, l'authentification se fait en NTLM, exposé au rejeu de l'empreinte du mot de passe (*pass-the-hash*) et au relais NTLM.
- **Surface d'exposition** : un port 5985 ouvert à tout le réseau permet à n'importe quelle machine de tenter de s'authentifier.
- **Privilèges excessifs** : un compte administrateur utilisé pour une simple collecte peut tout modifier sur les postes.
- **Confiance mal maîtrisée** : `TrustedHosts = *` ferait envoyer les identifiants à n'importe quelle machine, y compris une machine piégée.
- **Absence d'authentification du serveur** : en HTTP hors domaine, le poste d'administration ne peut pas vérifier l'identité du poste contacté.
- **Traçabilité insuffisante** : sans journalisation PowerShell, les commandes exécutées à distance laissent peu de traces.
- **Secrets et rapports sur le poste d'administration** : identifiants chiffrés, mot de passe de messagerie et rapports décrivant les failles du parc en font une cible de choix.

**Point 2 – Qui peut ouvrir une session distante ?**

Sur le point de terminaison standard (`microsoft.powershell`), trois entités sont autorisées : INTERACTIF, Administrateurs et Utilisateurs de gestion à distance. Sur chaque VM, le groupe Administrateurs contient `admin` et le compte Administrateur intégré (désactivé par défaut), et le groupe Utilisateurs de gestion à distance contient uniquement `svc_patch`. Le point de terminaison JEA `PatchManagement` n'accepte que `svc_patch`.

**Point 3 – Limitation des privilèges du compte de Patch Management**

Le script de durcissement crée sur chaque poste le compte local `svc_patch`, non administrateur, membre du seul groupe Utilisateurs de gestion à distance. Deux jeux d'identifiants chiffrés coexistent désormais sur le poste d'administration : `credentials\<NOM>.xml` pour `svc_patch`, utilisé par les Parties 2 à 7, et `credentials\<NOM>.admin.xml` pour `admin`, réservé au durcissement et à l'audit de sécurité.

Un compte non administrateur s'est avéré bloqué par défaut à deux niveaux :

1. **Lecture WMI refusée** : l'espace de noms WMI `root\cimv2` n'autorise les connexions distantes qu'aux administrateurs. Accorder à ce groupe les seuls droits « Activer le compte » et « Appel à distance autorisé » a résolu ce premier blocage.
2. **Correctifs invisibles** : `Get-HotFix` renvoie une liste vide à un compte non administrateur. Les postes paraissaient donc non conformes à tort, avec 3 correctifs « manquants » sur 3.

Remettre le compte administrateur aurait annulé tout le bénéfice. La solution retenue est JEA (point 7) : le compte reste non administrateur, et le droit WMI ajouté à l'étape 1, devenu inutile, a été retiré.

**LocalAccountTokenFilterPolicy est conservé à 1, en connaissance de cause.** À 0, le compte `admin` perdrait ses droits d'administration à distance : le durcissement, l'installation de JEA et l'audit de sécurité devraient se faire depuis la console de chaque VM. Le script de durcissement propose ce réglage (`-DisableLocalAdminRemote`). En production, on l'appliquerait et on administrerait les postes avec des comptes de domaine, que ce réglage ne concerne pas, et dont les mots de passe d'administrateur local seraient gérés par Windows LAPS.

**Point 4 – Accès aux fichiers produits par la solution**

L'audit vérifie les droits NTFS des dossiers `credentials` et `Rapports` et signale tout accès accordé à un groupe large (Tout le monde, Utilisateurs, Utilisateurs authentifiés). Le projet étant placé dans le profil de l'utilisateur, seuls SYSTEM, les administrateurs et cet utilisateur y ont accès. Les identifiants sont en plus chiffrés par DPAPI, donc inutilisables par un autre compte ou sur une autre machine, et le dossier `credentials` est exclu du dépôt Git.

Si le projet était déplacé dans un dossier partagé, les droits seraient à restreindre explicitement, par exemple :

```powershell
icacls .\credentials /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F"
```

**Point 5 – Règles du pare-feu associées à WinRM**

L'audit a révélé une faille passée inaperçue en Partie 1 : la règle créée par `Enable-PSRemoting` (`WINRM-HTTP-In-TCP-NoScope`) autorisait WinRM depuis **n'importe quelle adresse** sur un réseau privé. La règle restreinte au poste d'administration ne servait donc à rien, puisque Windows accepte une connexion dès qu'une seule règle l'autorise.

Le script de durcissement vérifie d'abord que la règle limitée à 192.168.93.1 existe, pour ne jamais couper l'accès du poste d'administration, puis désactive les règles par défaut. Relancer `Enable-PSRemoting` les réactiverait : l'audit de sécurité doit donc être relancé après toute intervention sur WinRM.

**Point 6 – Mode d'authentification et cas où Kerberos est préférable**

L'audit a relevé, depuis la session elle-même, le mode d'authentification réellement utilisé : **NTLM**, car les machines ne sont pas membres d'un domaine. L'authentification Basic est désactivée et le trafic non chiffré est refusé, côté client comme côté serveur.

Kerberos est préférable dès que les postes appartiennent à un domaine Active Directory :

- **authentification mutuelle** : le client vérifie aussi l'identité du serveur, ce qui rend `TrustedHosts` inutile ;
- **pas d'empreinte de mot de passe sur le réseau** : des tickets à durée limitée, qui résistent au relais et au *pass-the-hash* ;
- **gestion centralisée** : comptes, groupes et stratégies gérés dans l'annuaire, et délégation contrôlable.

Hors domaine, l'alternative est un écouteur **HTTPS** (port 5986) avec un certificat, qui authentifie le serveur et chiffre le transport par TLS.

**Point 7 – Just Enough Administration (JEA)**

JEA permet de créer un point de terminaison PowerShell qui n'expose qu'une liste précise de commandes à une liste précise de comptes. Il a été mis en œuvre sur les deux VM :

| Réglage | Effet |
| --- | --- |
| `RoleDefinitions` : `PCxx\svc_patch` → rôle `PatchAudit` | Seul le compte de service peut se connecter |
| `VisibleFunctions` : `Get-PatchAuditData` | Une seule commande visible, en lecture seule |
| `SessionType RestrictedRemoteServer` (langage *NoLanguage*) | Ni variables, ni scripts, ni appels .NET |
| `RunAsVirtualAccount` | Exécution sous un compte virtuel temporaire, administrateur local, créé pour la seule durée de la session |
| `TranscriptDirectory` | Chaque session est enregistrée dans `C:\ProgramData\JEA\Transcripts` |
| `ExecutionPolicy RemoteSigned` | Limitée à ce point de terminaison ; la stratégie du poste reste inchangée |

Le code de `Get-PatchAuditData` est exactement celui du module `PatchManager.psm1` (`Get-PatchAuditScript`) : la collecte est identique, quel que soit le point de terminaison. La fonction `Invoke-PatchAudit` passe automatiquement par JEA quand il est installé.

La vérification montre que `svc_patch` obtient les 5 correctifs de chaque poste, la collecte s'exécutant sous l'identité `WinRM Virtual Users\WinRM VA_1_PC01_svc_patch`.

Trois blocages successifs illustrent le principe de JEA, où tout est fermé par défaut :

1. **Stratégie d'exécution** : la stratégie *Restricted* de Windows client empêchait le chargement du module JEA. La stratégie RemoteSigned a été appliquée au seul point de terminaison.
2. **Modules non chargés** : une session JEA ne charge pas automatiquement les modules, et `Get-CimInstance` était introuvable. Le module JEA importe désormais explicitement `CimCmdlets`.
3. **Double importation** : importer `CimCmdlets` à la fois par la capacité de rôle et par le module provoquait une erreur sur un alias protégé. Une seule importation suffit.

**Point 8 – Stratégie de conservation des rapports et des journaux**

Certaines mesures sont déjà en place : droits NTFS restreints, identifiants chiffrés, journal alimenté uniquement par ajout, et copie horodatée de chaque rapport HTML dans `Rapports\Historique`. La stratégie complète pour un usage en production s'organise autour des trois menaces citées par le sujet :

| Menace | Mesures proposées |
| --- | --- |
| Modification non autorisée | Empreinte SHA-256 de chaque rapport archivé, conservée à part ou signée ; envoi du journal vers le journal d'événements Windows et un collecteur central (Windows Event Forwarding, SIEM) où l'opérateur ne peut pas le réécrire |
| Suppression | Droits NTFS refusant la suppression au compte d'exploitation ; sauvegarde sur un stockage externe non réinscriptible ; durée de conservation définie (par exemple un an), puis purge contrôlée |
| Exposition d'informations sensibles | Accès limité aux administrateurs ; chiffrement du disque (BitLocker) ; rapports retirés du dépôt Git, remplacés par un exemple anonymisé ; notifications envoyées uniquement par une messagerie interne |

Les rapports de ce projet listent précisément les postes vulnérables et les correctifs manquants : entre de mauvaises mains, ils constituent une carte des cibles prioritaires. Leur protection relève donc du même niveau d'exigence que celle des identifiants.

## Problèmes rencontrés et solutions

Le blocage le plus instructif a été un port WinRM fermé alors que le ping fonctionnait, causé par le retour de la carte host-only en profil réseau Public.

| Problème | Cause | Solution |
| --- | --- | --- |
| `Test-WSMan` échoue sur les deux VM alors que le ping répond (`TcpTestSucceeded : False` sur le port 5985) | La carte host-only, sans passerelle, est vue comme un « réseau non identifié » et repasse en profil Public. La règle WinRM de Windows client ne couvre que les profils Domaine et Privé | Profil remis en Privé, et règle de pare-feu `-Profile Any` limitée à l'adresse du poste d'administration |
| Script refusé : *is not digitally signed* | Fichier téléchargé depuis le navigateur, donc marqué « provenant d'Internet » (Mark of the Web). Avec la stratégie RemoteSigned, un tel fichier doit être signé | `Unblock-File` après vérification du contenu |
| Accents mal affichés dans Windows PowerShell 5.1 | PowerShell 5.1 lit un fichier UTF-8 sans BOM comme du texte ANSI | Fichiers enregistrés en UTF-8 avec BOM |
| VM bloquée sur *EFI Network… Time out* au premier démarrage | Le délai « Press any key to boot from CD » a expiré et la VM a tenté un démarrage réseau | Redémarrage en appuyant immédiatement sur une touche |
| Carte host-only en 169.254.x.x | Le DHCP est désactivé sur VMnet1 | Adresse IP fixe |
| Commande refusée : paramètre introuvable | Fautes de saisie (`-PrefixLenght`, `-Protocole`) : les paramètres PowerShell sont toujours en anglais | Copier-coller des commandes |
| `git push` rejeté : *Internal Server Error* | Erreur côté serveur GitHub, temporaire | Nouvelle tentative plus tard |

Le premier problème illustre la différence entre `Test-Connection`, qui vérifie la joignabilité réseau (ICMP), et `Test-WSMan`, qui vérifie que le service WinRM répond réellement sur le port 5985. Une machine peut répondre au ping tout en restant inaccessible pour PowerShell Remoting.

Un dernier problème est apparu après le rangement des scripts dans des sous-dossiers : les scripts cherchaient le module et les fichiers de configuration dans leur propre dossier (`$PSScriptRoot`) et ne les trouvaient plus. Le script de la Partie 3 avait pourtant fonctionné, car le module était resté chargé en mémoire. La correction a consisté à centraliser les chemins dans le module (`Get-ProjectPaths`) et à rendre l'échec de chargement bloquant (`-ErrorAction Stop`).

Lors des tests de la Partie 4, l'export CSV a échoué parce que le fichier était ouvert dans Excel, qui le verrouille. Le script annonçait pourtant un enregistrement réussi. La fonction `Export-ReportCsv` du module corrige ce point : si le fichier cible est verrouillé, les résultats sont écrits dans un fichier horodaté voisin, un avertissement est affiché, et le message final indique le fichier réellement écrit.

## Choix techniques et sécurité

Dès la préparation de l'environnement, chaque ouverture d'accès a été limitée au strict nécessaire. Ces choix serviront de base à la Partie 8.

| Choix | Justification | Point de vigilance |
| --- | --- | --- |
| Réseau host-only dédié à l'administration | WinRM n'est exposé que sur un réseau privé entre l'hôte et les VM | Le profil Public peut revenir après redémarrage |
| Règle WinRM limitée à 192.168.93.1 | Seul le poste d'administration peut ouvrir une session distante | Toute nouvelle machine d'administration doit être ajoutée explicitement |
| TrustedHosts limité aux IP des VM | L'hôte n'envoie pas d'identifiants vers une machine inconnue | Liste à maintenir quand le parc évolue |
| Stratégie d'exécution RemoteSigned, portée utilisateur | Scripts locaux autorisés, scripts téléchargés soumis à signature | `Unblock-File` ne doit être appliqué qu'après lecture du script |
| Identifiants saisis avec `Get-Credential` | Le mot de passe est stocké chiffré en mémoire, jamais en clair dans un script | À conserver pour les parties suivantes, notamment la notification |
| Snapshots des VM (installation propre, WinRM OK) | Retour rapide à un état fonctionnel après une modification risquée | — |

Deux points affaiblissent la sécurité et devront être discutés :

- **`LocalAccountTokenFilterPolicy`**, activé par `Enable-PSRemoting`, désactive le filtrage UAC pour les comptes locaux connectés à distance. Un compte administrateur local compromis devient alors utilisable sur le réseau.
- **WinRM en HTTP et NTLM** : hors domaine, Kerberos n'est pas disponible. Le contenu des sessions WinRM reste chiffré par la négociation NTLM, mais l'authentification mutuelle des machines n'est pas garantie. HTTPS (port 5986) ou un domaine Active Directory avec Kerberos seraient préférables en production.

## État d'avancement

L'environnement est prêt et les points 1 à 4 de la Partie 1 sont validés.

- [x] Environnement de test : hôte + 2 VM Windows 11 Professionnel en réseau host-only
- [x] Partie 1, points 1 à 6 : connectivité, inventaire, disponibilité, WinRM, Enter-PSSession, Invoke-Command
- [x] Partie 1 : réponses aux questions
- [x] Partie 2 : inventaire du parc
- [x] Partie 3 : inventaire des correctifs
- [x] Réorganisation du projet (Config, Scripts\\PartieN, module commun) et README
- [x] Partie 4 : contrôle de conformité et question 7
- [x] Partie 6 : rapport de sécurité (CSV, HTML, historique, journal)
- [x] Partie 7 : notification et questions 2 et 3
- [x] Partie 8 : audit, durcissement, compte de service, JEA, stratégie de conservation
- [ ] Insertion des captures d'écran et relecture du rapport
- [ ] Vidéo de démonstration (environ 15 minutes)
