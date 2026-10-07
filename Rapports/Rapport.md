# Rapport – Système de gestion des mises à jour en PowerShell

Oct 7, 2026 · @Adrien

## Introduction

Ce projet met en place une solution simplifiée de Patch Management pour un parc Windows, entièrement pilotée en PowerShell depuis un poste d'administration central.

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
├── Config\            computers.txt, required-patches.txt
├── credentials\       identifiants chiffrés (exclu de Git)
├── Rapports\          CSV, rapports HTML, journal
├── Screenshots\       captures par partie
└── Scripts\
    ├── Commun\        PatchManager.psm1, Initialize-Credentials.ps1
    ├── Partie1\       Partie1-Disponibilite.ps1, Partie1-InvokeCommand.ps1
    ├── Partie2\       Partie2-Inventaire.ps1
    └── Partie3\       Partie3-Correctifs.ps1
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
- [x] Réorganisation du projet (Config, Scripts\\PartieN, module commun)
- [ ] Partie 4 : contrôle de conformité
- [ ] Partie 6 : rapport de sécurité
- [ ] Partie 7 : notification
- [ ] Partie 8 : sécurisation
