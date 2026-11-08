# Sécurité et gestion des accès

## 1. Comptes et groupes Active Directory (tâche B)

Créés par `scripts/windows/s3_ad_structure.ps1` (idempotent, aucun secret dans le fichier : le mot de passe des comptes de test est saisi à l'exécution).

### Arborescence

```
infraready.test
└── OU=InfraReady            (protégée contre la suppression accidentelle)
    ├── OU=Utilisateurs      a.martin, s.bernard, u.durand, u.petit
    └── OU=Groupes           GG_InfraReady_*, DL_Partage_Docs_*
```

### Méthode AGDLP

Comptes → groupes **globaux** (métier) → groupes **domaine local** (ressource) → **permissions**.
Les droits ne sont posés que sur les groupes `DL_` : un changement de poste = changement de groupe, jamais de retouche des ACL.

| Compte (test) | Groupe global | Groupe domaine local | Droit NTFS sur `C:\Partages\Docs` |
|---|---|---|---|
| a.martin | GG_InfraReady_Admins | DL_Partage_Docs_RW | **M** (lire, créer, modifier, supprimer) |
| s.bernard | GG_InfraReady_Support | DL_Partage_Docs_RO | **RX** (lecture seule) |
| u.durand, u.petit | GG_InfraReady_Utilisateurs | DL_Partage_Docs_RO | **RX** (lecture seule) |
| — | Administrators, SYSTEM | — | **F** (administration) |

**Choix de moindre privilège** : le support consulte les procédures mais ne les modifie pas ; seule l'équipe d'administration écrit.

### Partage `\\WIN-DC01\Docs`

- Permissions de **partage** volontairement larges (Authenticated Users : Modifier ; Administrators : Contrôle total) ; le filtrage fin est fait par **NTFS**. Windows applique la plus restrictive des deux couches.
- **Héritage NTFS coupé** (`icacls /inheritance:r`) : aucun droit hérité de `C:\` (ex. `BUILTIN\Users`).
- Limite connue : partage hébergé sur le contrôleur de domaine pour le laboratoire ; en production, un serveur de fichiers membre serait préférable.

### Traçabilité

Les créations sont journalisées dans le journal **Security** du DC : 4720 (compte créé), 4727/4731 (groupe global/local créé), 4728/4732 (membre ajouté à un groupe global/local).

```powershell
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4720,4727,4728,4731,4732,4756; StartTime=(Get-Date).AddHours(-2)}
```

## 2. Accès d'administration

| Accès | Méthode | Compte | Restriction |
|---|---|---|---|
| Linux (LINUX01) depuis OPS01 | SSH, clé ed25519 protégée par passphrase + ssh-agent | `ansible` (sudo) | Réseau labo uniquement |
| Linux depuis l'hôte | SSH, mot de passe | `nalyug` (nominatif, sudo) | Réseau labo uniquement ; root non connectable |
| Windows (WIN-DC01) | WinRM 5985 (profil réseau Domain) | comptes du domaine autorisés | Réseau labo uniquement |
| Ping vers le DC | ICMPv4 echo | — | Règle « LAB - ICMPv4 echo depuis 192.168.50.0/24 » |

## 3. Filtrage réseau (moindre privilège réseau)

Politique : **tout refuser en entrée, puis n'ouvrir que ce qu'un flux documenté exige**, et seulement depuis la source qui en a besoin. Règles posées par Ansible (`linux.yml`, `monitoring.yml`), donc reproductibles et vérifiables.

| Machine | Port | Source autorisée | Motif | Posée par |
|---|---|---|---|---|
| LINUX01 | 22/tcp | 192.168.50.0/24 | SSH administration + Ansible | `linux.yml` (ufw) |
| LINUX01 | 80/tcp | 192.168.50.0/24 | Site web | `linux.yml` (ufw) |
| LINUX01 | 9100/tcp | **192.168.50.30 seul** | Collecte Prometheus | `linux.yml` (ufw) |
| OPS01 | 22, 9090, 3000/tcp | 192.168.50.0/24 | SSH, Prometheus, Grafana | `monitoring.yml` (ufw) |
| OPS01 | 9100/tcp | — (non ouvert) | node_exporter lu en local (`localhost`) | — |
| WIN-DC01 | 9182/tcp | **192.168.50.30 seul** | Collecte Prometheus | `monitoring.yml` (« LAB - windows_exporter depuis OPS01 ») |
| WIN-DC01 | 53, 88, 389, 445, 5985… | profil Domaine | Services AD/DNS/WinRM | rôles Windows |

- `ufw` est activé **après** l'ajout de la règle SSH : sinon Ansible se couperait lui-même l'accès.
- `logging low` : les paquets refusés sont tracés dans `/var/log/ufw.log` (`[UFW BLOCK]`), ce qui sert au diagnostic (voir [incident.md](incident.md)).
- Les collecteurs exposent des informations sur le système (versions, services, disques) : ils ne sont joignables que par Prometheus.
- Grafana : consultation anonyme en **lecture seule** (rôle Viewer, port 3000 limité au labo) pour l'écran de supervision ; administration par le compte `admin` (mot de passe changé, hors dépôt) ; inscription désactivée ; tableaux de bord non modifiables depuis l'interface (`allowUiUpdates: false`). En production : authentification AD (LDAP) au lieu de l'anonyme.

## 4. Sécurité de la chaîne d'automatisation

| Mesure | Mise en œuvre |
|---|---|
| Vérification des clés d'hôte SSH | `host_key_checking = True` (`ansible.cfg`) : un serveur usurpé est refusé |
| Paquets vérifiés | apt vérifie les signatures (dépôt Grafana limité à sa propre clé via `signed-by`) ; MSI windows_exporter contrôlé par **SHA-256** avant copie sur le DC |
| Validation avant remplacement | `promtool check config/rules` en `validate` : une config invalide ne remplace jamais celle en service |
| CI en moindre privilège | `permissions: contents: read` : le workflow ne peut rien écrire dans le dépôt |
| Pas d'accès CI au labo | runner hébergé GitHub sans route vers 192.168.50.0/24, aucun secret du labo dans GitHub |
| Détection de secrets | `gitleaks` sur **tout l'historique** à chaque push + motifs vérifiés par `controle_coherence.py` |
| Traçabilité | chaque changement = un commit Git expliqué ; maintenance tracée dans `/var/log/infraready-maintenance.log` |

## 5. Secrets

Aucun mot de passe, clé privée ni jeton dans le dépôt (`.gitignore` exclut clés, fichiers Vault et MSI). Les secrets (Administrator, DSRM, comptes Linux, passphrase de la clé SSH, `svc_ansible`, mot de passe des comptes de test, admin Grafana) sont conservés dans un gestionnaire de mots de passe et **saisis à l'exécution** (`-K` sudo, `-k` WinRM).

Si une variable sensible devait être stockée (ex. mot de passe Grafana), elle le serait chiffrée avec Ansible Vault :

```bash
ansible-vault create inventory/group_vars/supervision/vault.yml   # chiffré AES-256
ansible-playbook playbooks/monitoring.yml --ask-vault-pass
```

Les captures de preuves sont relues avant publication : aucun mot de passe ni jeton visible.
