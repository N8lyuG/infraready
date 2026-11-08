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

## 3. Secrets

Aucun mot de passe, clé privée ni jeton dans le dépôt. Les secrets (Administrator, DSRM, comptes Linux, passphrase de la clé SSH, mot de passe des comptes de test) sont conservés dans un gestionnaire de mots de passe ; Ansible Vault sera utilisé pour les variables sensibles (S4/S7).
