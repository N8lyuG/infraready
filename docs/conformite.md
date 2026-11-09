# Conformité au sujet : exigences → réalisation → preuves

Vérification finale demandée en séance 8 : chaque exigence du sujet officiel InfraReady est reliée à
ce qui a été réalisé, à l'endroit où c'est versionné et à la preuve qui le démontre.

**Statuts** (support S8, §3.1) : **Validé** = testé et prouvé · **Partiel** = une partie manque ·
**Non validé** = absent ou en échec · **Non vérifiable** = l'environnement ne permet pas de conclure.

Les preuves (`SXX_NN_…`) sont dans le dossier `preuves/` hors dépôt, reprises dans le
[dossier technique](dossier-technique.pdf) ; les journaux bruts sont produits par
`scripts/linux/deployer-labo.sh`. État relevé le 09/11/2026.

## A. Installation et réseau

| Exigence | Réalisation | Où | Preuve | Statut |
|---|---|---|---|---|
| Créer les machines virtuelles | WIN-DC01, LINUX01, OPS01 sous VMware, UEFI, snapshots `00` à `04` | [architecture.md](architecture.md) | S02_00, S02_07 (état des VM) | Validé |
| Noms d'hôtes et adresses IP | IP fixes `.10/.20/.30`, Netplan sur les Linux | [adressage-ip.md](adressage-ip.md) | S02_04, S02_06 | Validé |
| Réseau virtuel adapté | VMnet1 host-only sans passerelle ; NAT temporaire refermée | [architecture.md](architecture.md) | S02_00, S06_16b, S06_16c | Validé |
| Tester la connectivité | Tests T01 à T08 depuis les 3 machines : 24/24 | — | S02_07_T01-T08 | Validé |
| Configurer et tester le DNS | Zone `infraready.test` (A, PTR, SRV), résolution testée depuis les Linux | [adressage-ip.md](adressage-ip.md) | S02_05, S02_07 | Validé |
| Schéma d'architecture | Schéma des flux | [architecture.md](architecture.md), README, dossier §2 | — | Validé |

## B. Administration Windows

| Exigence | Réalisation | Où | Preuve | Statut |
|---|---|---|---|---|
| Rôle AD DS + domaine | Domaine `infraready.test`, niveau 2025 | [architecture.md](architecture.md) | S02_05 | Validé |
| Configurer DNS | DNS intégré AD, zone inverse | [adressage-ip.md](adressage-ip.md) | S02_05b | Validé |
| ≥ 2 groupes et plusieurs comptes de test | 3 groupes globaux, 2 domaine local (AGDLP), 4 comptes | `scripts/windows/s3_ad_structure.ps1` | S03_01, S03_02 | Validé |
| Documenter droits et accès | Tableau AGDLP, NTFS, partage, moindre privilège | [securite.md](securite.md) §1-2 | S03_01 | Validé |
| Journaux Windows utiles | Security (4720, 4728, 4732, 4625), System (7036) | [securite.md](securite.md), [maintenance.md](maintenance.md) | S03_03, S04_09b, S04_20c | Validé |

## C. Administration Linux

| Exigence | Réalisation | Où | Preuve | Statut |
|---|---|---|---|---|
| Comptes, groupes, permissions | Groupe `infraready-data`, `/srv/infraready` 2770, tests autorisé / refusé | [scenarios-pannes.md](scenarios-pannes.md), dossier §5 | S04_07 | Validé |
| Service applicatif | Nginx déployé par Ansible, contrôle HTTP + contenu | `playbooks/linux.yml` | S04_15, S04_17, S05_02b | Validé |
| Services et processus | `systemctl`, `ps`, `ss`, `check-nginx.sh` | `scripts/linux/check-nginx.sh` | S04_08, S04_10, S04_17 | Validé |
| Disque de test + système de fichiers + montage | `sdb` identifié par 4 critères, ext4, fstab par UUID, persistance après redémarrage | dossier §5 | S04_02 à S04_06, S04_19, S06_17 | Validé |
| Mises à jour contrôlées | `maintenance.yml` (apt *safe*, contrôles avant/après), redémarrage encadré | `playbooks/maintenance.yml`, [maintenance.md](maintenance.md) | S06_07a, S06_17 | Validé |
| Journaux système | `journalctl`, `auth.log`, `ufw.log` utilisés en diagnostic | [incident.md](incident.md) | S02_06, S06_13d, S04_30c | Validé |

## D. Automatisation Ansible

| Exigence | Réalisation | Où | Preuve | Statut |
|---|---|---|---|---|
| Inventaire des hôtes | Groupes `linux`, `supervision`, `windows` | `inventory/hosts.yml` | S05_01c ; CI (`ansible-inventory`) | Validé |
| Variables nécessaires | Seuils, ports, services critiques, `acces_internet` | `inventory/group_vars/` | — | Validé |
| ≥ 1 playbook Linux | `linux.yml`, `monitoring.yml`, `maintenance.yml`, `verification.yml` | `playbooks/` | S05_02b, S05_04a | Validé |
| ≥ 1 playbook Windows | `windows.yml` + parties Windows des autres playbooks | `playbooks/windows.yml` | S04_21, S05_04c | Validé |
| Vérifications après exécution | `assert` sur services, contrôle HTTP `uri` + `assert`, `verification.yml` | `playbooks/` | S06_05a-c, S04_31a | Validé |
| Dépendances et commandes documentées | `requirements.yml`, prérequis et commandes | README, dossier §4 | — | Validé |
| Second passage stable | `changed=0` sur tous les playbooks | — | S04_16, S04_22, S05_02c, S05_05a-c | Validé |
| Erreurs traitées | `block/rescue` Windows Update, arrêt si état initial dégradé, 6 scénarios de panne | [scenarios-pannes.md](scenarios-pannes.md) | S06_07c, S04_24 à S04_31 | Validé |

## E. Maintenance et mises à jour

| Exigence | Réalisation | Où | Preuve | Statut |
|---|---|---|---|---|
| Procédure de maintenance | Fréquence, ordre, fenêtre, retour arrière | [maintenance.md](maintenance.md) | — | Validé |
| Mises à jour Linux automatisées | `maintenance.yml` : LINUX01 `changed=3`, OPS01 `changed=2` | `playbooks/maintenance.yml` | S06_07a, S06_07b | Validé |
| Procédure Windows documentée et testée | Procédure documentée ; test réel : Windows Update injoignable (DC sans Internet) géré par `rescue` | [maintenance.md](maintenance.md) §4 | S06_07c | **Partiel** — mises à jour non appliquées : il faut brancher une carte NAT temporaire sur le DC (procédure prête) |
| Espace disque et services | Contrôles bloquants avant MAJ, `verification.yml`, alertes | `playbooks/` | S06_05a-c | Validé |
| Précautions avant redémarrage | Snapshot, état sain, espace, console, DC en dernier | [maintenance.md](maintenance.md) §2 | S06_17 | Validé |

## F. Supervision

| Exigence | Réalisation | Où | Preuve | Statut |
|---|---|---|---|---|
| Installer Prometheus | Paquet Ubuntu, config et règles validées par `promtool` | `monitoring/prometheus.yml`, `playbooks/monitoring.yml` | S05_04a | Validé |
| Collecteurs Linux et Windows | node_exporter ×2, windows_exporter 0.32.1 | `playbooks/monitoring.yml` | S05_04b-c, S06_01 (4 cibles UP) | Validé |
| Prometheus comme source Grafana | Provisionnée par fichier | `monitoring/grafana/provisioning/` | S06_03 | Validé |
| Tableau de bord CPU, mémoire, stockage, disponibilité | 8 panneaux, données réelles | `monitoring/dashboards/infraready.json` | S06_03 | Validé |
| Provenance des métriques expliquée | Trajet système → collecteur → Prometheus → Grafana | [supervision.md](supervision.md) | — | Validé |
| ≥ 1 seuil ou alerte démontré | `HoteInjoignable` (incident H) et `ServiceLinuxArrete` (scénario 5), déclenchées puis résolues | `monitoring/rules/alertes.yml` | S06_12b, S06_12, S04_30b | Validé |

## G. GitHub et intégration continue

| Exigence | Réalisation | Où | Preuve | Statut |
|---|---|---|---|---|
| Dépôt GitHub | https://github.com/N8lyuG/infraready | — | S07_02 | Validé |
| Organisation des fichiers | Voir « Écarts » ci-dessous | README | — | Validé |
| Commits compréhensibles | Messages expliquant le pourquoi | historique Git | — | Validé |
| Workflow GitHub Actions | 4 jobs : lint Ansible, supervision, scripts, secrets | `.github/workflows/validation.yml` | — | Validé |
| Déclenché à chaque push / PR | `on: push, pull_request` | `.github/workflows/validation.yml` | — | Validé |
| Preuve d'exécution réussie | Run vert ; un échec (`shellcheck`) analysé et corrigé | — | S07_01 | Validé |
| Les deux membres contribuent au dépôt (sujet §3) | — | — | — | **Partiel** — un seul auteur dans l'historique à ce jour |

## H. Diagnostic d'incident

| Exigence | Réalisation | Où | Preuve | Statut |
|---|---|---|---|---|
| Incident simple, contrôlé, réversible | Perte de collecte de LINUX01 (règle ufw 9100) | [incident.md](incident.md) | S06_11 | Validé |
| Symptôme | `HoteInjoignable` firing, Grafana HORS SERVICE | [incident.md](incident.md) §1 | S06_12, S06_12b, S06_12c | Validé |
| Tests et journaux | 8 tests du général au précis, `ufw.log` | [incident.md](incident.md) §2 | S06_13a-d | Validé |
| Cause | Règle supprimée + politique `deny` | [incident.md](incident.md) §3 | S06_13d | Validé |
| Correction | Rejeu de `linux.yml` (`changed=1`) | [incident.md](incident.md) §4 | S06_14a-b | Validé |
| Retour à la normale | 0 alerte, HTTP 200, 4 cibles up, 2e passage `changed=0` | [incident.md](incident.md) §5 | S06_15a-e | Validé |

## Livrables (sujet §9)

| Livrable | Emplacement | Statut |
|---|---|---|
| 1. Dépôt GitHub | https://github.com/N8lyuG/infraready | Validé |
| 2. Dossier technique PDF référençant le dépôt | [dossier-technique.pdf](dossier-technique.pdf) | Validé |
| 3. Preuves de fonctionnement | `preuves/` + dossier technique (annexe) | Validé |
| 4. Rapport d'incident | [incident.md](incident.md) (+ [scenarios-pannes.md](scenarios-pannes.md)) | Validé |
| 5. Démonstration + PowerPoint | [presentation_orale.pptx](presentation_orale.pptx) / [.pdf](presentation_orale.pdf) | Validé (soutenance le 10/11) |

## Écarts à la structure de dépôt recommandée

La structure du sujet est une proposition « qui peut évoluer si l'organisation reste cohérente et
documentée ». Écarts retenus :

| Recommandé | Réalisé | Raison |
|---|---|---|
| `group_vars/` à la racine | `inventory/group_vars/` | Ansible charge `group_vars` à côté du **fichier d'inventaire** ou du **playbook**. L'inventaire est dans `inventory/` et les playbooks dans `playbooks/` : un `group_vars/` à la racine ne serait lu par aucune commande. |
| `roles/` | absent | Aucun rôle n'est utilisé : chaque playbook est court et lisible. Un dossier `roles/` vide laisserait croire à une organisation qui n'existe pas. Factoriser en rôles est une suite possible. |
| — | `docs/supervision.md`, `docs/scenarios-pannes.md`, `docs/conformite.md` | Documents ajoutés : supervision (S6), scénarios de panne et compte rendu (S4), présente matrice (S8). |
| — | `ansible.cfg`, `requirements.yml`, `.yamllint`, `.ansible-lint` | Configuration d'Ansible et des contrôles exécutés en CI. |
| — | `scripts/outils/` | Génération du tableau de bord et contrôle de cohérence utilisés par la CI. |

## Points partiels et non réalisés

| Point | Raison | Pour finaliser |
|---|---|---|
| Mises à jour Windows non appliquées | DC volontairement sans Internet | Snapshot, carte NAT temporaire sur WIN-DC01, puis `ansible-playbook playbooks/maintenance.yml --limit windows -k -e appliquer_maj_windows=true` |
| Contribution des deux membres | Historique à un seul auteur | Commits du binôme (relecture de la doc, compléments) |
| WinRM en HTTP (5985) | Pas d'autorité de certification dans le labo | Certificat + listener HTTPS 5986 |
| `svc_ansible` dans *Domain Admins* | Simplicité du labo | Délégation limitée ou JEA |
| Pas d'Alertmanager | Hors périmètre | Alertmanager + notification e-mail |
| Pas de NTP centralisé pour les Linux | Non configuré (≈ 2 s d'écart constaté au scénario 4) | `timesyncd` pointé sur WIN-DC01 |
