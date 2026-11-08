# Procédure de maintenance et de mise à jour (tâche E)

Objectif : appliquer les mises à jour **sans casser le service** et pouvoir **revenir en arrière** à tout moment. La maintenance est automatisée par `playbooks/maintenance.yml` ; elle est encadrée par des contrôles avant/après et par `playbooks/verification.yml`.

## 1. Fenêtre et fréquence

| Élément | Choix InfraReady | Pourquoi |
|---|---|---|
| Linux (LINUX01, OPS01) | Hebdomadaire ; correctifs de sécurité critiques sous 48 h | Les dépôts Ubuntu publient en continu ; `apt` est rapide et réversible par snapshot |
| Windows (WIN-DC01) | Mensuelle, après le « Patch Tuesday » (2e mardi) | Rythme de publication Microsoft ; un redémarrage du DC coupe l'authentification et le DNS |
| Ordre | LINUX01 → OPS01 → WIN-DC01 | Le service applicatif d'abord ; le DC (dont tout dépend) en dernier, seul |
| Fenêtre | Hors heures d'utilisation, 1 h prévue | Le temps de restaurer un snapshot si besoin |

## 2. Précautions avant redémarrage ou changement majeur

1. **Snapshot** de la VM concernée (VM éteinte de préférence : snapshot cohérent, sans état mémoire) — nommé `NN-avant-<intervention>`.
2. **État initial sain** : `verification.yml` sans échec. On ne met pas à jour un système déjà en panne : on ne saurait plus attribuer la cause.
3. **Espace disque** : ≥ 1 Go libre sur `/` (Linux), ≥ 5 Go sur `C:` (Windows). Contrôlé automatiquement, la maintenance s'arrête sinon.
4. **Accès de secours** : console VMware disponible (si SSH ou le réseau ne revient pas, on garde la main).
5. **Dépendances** : redémarrer WIN-DC01 coupe le DNS et l'authentification de tout le labo → prévenir, le faire en dernier.
6. **Carte NAT temporaire** branchée uniquement le temps des téléchargements, puis débranchée (le labo reste isolé).
7. **Traçabilité** : intervention notée (journal `/var/log/infraready-maintenance.log` alimenté par Ansible + commit Git si la configuration change).

## 3. Linux — procédure automatisée

```bash
# Sur OPS01, depuis la racine du dépôt (snapshot fait, NAT branchée)
ansible-playbook playbooks/verification.yml --limit linux -K        # 1. état initial
ansible-playbook playbooks/maintenance.yml  --limit linux -K        # 2. mises à jour, sans redémarrage
ansible-playbook playbooks/maintenance.yml  --limit linux -K -e autoriser_redemarrage=true   # 3. si "REDEMARRAGE REQUIS"
ansible-playbook playbooks/verification.yml --limit linux -K        # 4. retour à la normale
```

Ce que fait `maintenance.yml` (play Linux, `serial: 1` = une machine à la fois) :

| Étape | Tâche | Bloquant si… |
|---|---|---|
| Avant | `service_facts` + assert sur `services_critiques` | un service critique est déjà arrêté |
| Avant | Espace libre sur `/` | < `seuil_disque_min_maj_mo` (1024 Mo) |
| Avant | `journalctl -p err -b` (affiché, non bloquant) | — |
| MAJ | `apt list --upgradable` puis `apt upgrade` mode **safe** | — |
| MAJ | `autoremove` + `autoclean` | — |
| Redémarrage | `/var/run/reboot-required` ? | redémarre **seulement** avec `autoriser_redemarrage=true` ; **jamais OPS01** (il porte Ansible) |
| Après | Services critiques toujours actifs | un service ne tourne plus |
| Trace | Ligne datée dans `/var/log/infraready-maintenance.log` | — |

`upgrade: safe` plutôt que `dist` : `safe` n'enlève jamais de paquet. `dist` peut retirer un paquet pour résoudre une dépendance, et un service peut en dépendre. Les montées de version majeures (24.04 → 26.04) sont hors procédure : snapshot + `do-release-upgrade` manuel + recette complète.

OPS01 se met à jour en local (`--limit supervision`) ; s'il doit redémarrer, on le fait à la main depuis la console après la maintenance des autres machines.

## 4. Windows — procédure (mécanisme natif Windows Update)

WIN-DC01 n'a pas d'accès Internet en exploitation. Procédure testée :

1. Snapshot `NN-avant-maj-windows` (VM éteinte).
2. Ajouter une carte réseau NAT temporaire à WIN-DC01 (VMware > Settings > Add > Network Adapter > NAT).
3. Recherche seule, sans rien installer :
   `ansible-playbook playbooks/maintenance.yml --limit windows -k`
   → contrôles des services (`DNS`, `NTDS`, `Netlogon`, `WinRM`, `windows_exporter`) et de l'espace sur C:, liste des mises à jour trouvées.
4. Installation : `ansible-playbook playbooks/maintenance.yml --limit windows -k -e appliquer_maj_windows=true`
   (catégories : sécurité, critiques, cumulatives, définitions Defender ; `reboot: false`). Journal : `C:\InfraReady\windows-update.log`.
5. Redémarrage **manuel** du DC si `reboot_required` (console VMware ou `Restart-Computer`), en dernier, quand les Linux sont terminés.
6. Retirer la carte NAT, puis `ansible-playbook playbooks/verification.yml --limit windows -k`.
7. Contrôle complémentaire : `Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5` et journal *System* (source `Microsoft-Windows-WindowsUpdateClient`, ID 19 = installation réussie, 20 = échec).

Alternative manuelle équivalente : `sconfig` → option 6 (Install updates) ou Paramètres > Windows Update.

Si la carte NAT est absente, la tâche Windows Update échoue proprement (bloc `rescue`) en expliquant la procédure, sans faire échouer le reste.

## 5. Contrôles de l'espace disque et des services

| Contrôle | Linux | Windows | Automatisé par |
|---|---|---|---|
| Espace disque | `df -h`, `ansible_facts.mounts` | `Get-Volume` | `verification.yml` (seuil 80 %), alertes `DisqueLinuxPresquePlein` / `DisqueWindowsPresquePlein` |
| Services | `systemctl is-active`, `scripts/linux/check-nginx.sh` | `Get-Service`, `Check-DnsClient.ps1` | `verification.yml`, alertes `ServiceLinuxArrete` / `ServiceWindowsArrete` |
| Journaux | `journalctl -p err -b`, `journalctl -u <service>` | `Get-WinEvent -LogName System -MaxEvents 50` | `maintenance.yml` (affichage) |
| Disponibilité | `up` dans Prometheus | `up` dans Prometheus | alerte `HoteInjoignable` |

Le seuil de 80 % est défini une seule fois (`inventory/group_vars/all.yml` : `seuil_disque_pct`) et repris dans les règles Prometheus.

## 6. Retour arrière

| Situation | Action |
|---|---|
| Service cassé après une mise à jour | `journalctl -u <service>`, puis `apt install <paquet>=<version>` ; sinon snapshot |
| Machine qui ne redémarre pas | Console VMware ; sinon restauration du snapshot `NN-avant-…` |
| Mise à jour Windows problématique | `wusa /uninstall /kb:<numéro>` ou restauration du snapshot |

Après tout retour arrière : relancer `verification.yml` et noter l'événement dans `docs/incident.md` s'il y a eu impact.
