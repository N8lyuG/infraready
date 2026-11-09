# Supervision (tâche F) — Prometheus, collecteurs et Grafana

Déploiement : `playbooks/monitoring.yml`. Configuration versionnée : `monitoring/prometheus.yml`,
`monitoring/rules/alertes.yml`, `monitoring/grafana/provisioning/`, tableau généré par
`scripts/outils/generer_dashboard.py` → `monitoring/dashboards/infraready.json`.

## 1. Trajet d'une métrique

```
système (noyau Linux / WMI Windows)
  → collecteur HTTP (node_exporter :9100 sur LINUX01 et OPS01, windows_exporter :9182 sur WIN-DC01)
  → Prometheus sur OPS01 vient lire /metrics toutes les 15 s (modèle « pull »), stocke la série temporelle
  → règles d'alerte évaluées toutes les 15 s
  → Grafana interroge Prometheus (PromQL) et affiche le tableau de bord
```

Conséquence du modèle *pull* : c'est **OPS01 qui ouvre la connexion**. Le pare-feu de chaque cible
n'autorise donc le port du collecteur que depuis `192.168.50.30` (voir [securite.md](securite.md)).

## 2. Cibles attendues et observées

| Job | Instance | Adresse | Collecteur | État vérifié |
|---|---|---|---|---|
| prometheus | OPS01 | localhost:9090 | Prometheus lui-même | UP |
| node | LINUX01 | 192.168.50.20:9100 | node_exporter (+ collecteur systemd) | UP |
| node | OPS01 | localhost:9100 | node_exporter (+ collecteur systemd) | UP |
| windows | WIN-DC01 | 192.168.50.10:9182 | windows_exporter 0.32.1 | UP |

Preuves : `S06_01_prometheus_targets_4_up.png`, `S06_05d_prometheus_cibles.png` ; contrôle
automatique dans `playbooks/verification.yml` (toutes les cibles `up`). La cohérence inventaire ↔
cibles est vérifiée en CI par `scripts/outils/controle_coherence.py`.

## 3. Tableau de bord « InfraReady - etat du laboratoire »

Accès : `http://192.168.50.30:3000/d/infraready-labo` (lecture seule anonyme, réseau du labo).
Période par défaut : 30 dernières minutes, rafraîchissement 30 s.

| Panneau | Requête (résumé) | Unité | Ce qu'il permet de décider |
|---|---|---|---|
| Disponibilité des collecteurs | `up{job=~"node|windows"}` | EN SERVICE / HORS SERVICE | Une machine (ou sa collecte) est-elle perdue ? Point de départ de tout diagnostic |
| Services critiques | `node_systemd_unit_state{state="active"}`, `windows_service_state{state="running"}` | EN SERVICE / HORS SERVICE | Le service applicatif (nginx, DNS, NTDS…) tourne-t-il, indépendamment de la machine ? |
| CPU utilisé | `100 * (1 - rate(…idle[2m]))` | % | Charge anormale durable (seuil 85 %) ou pic ponctuel sans gravité |
| Mémoire utilisée | `1 - MemAvailable / MemTotal` (Linux), `available / physical_total` (Windows) | % | Saturation réelle (le cache récupérable est déduit sous Linux) |
| Stockage utilisé | `1 - avail / size` par point de montage / volume | % | Tendance de remplissage avant d'atteindre 80 % |
| Remplissage des volumes | même requête, valeur instantanée | % (jauges) | Comparaison rapide des volumes au seuil de 80 % |
| Durée depuis le dernier démarrage | `time() - node_boot_time_seconds` | durée | Un redémarrage non planifié remet le compteur à zéro |
| Alertes Prometheus | liste des alertes pending / firing | — | Ce qui demande une action maintenant |

### Distinguer une absence de données d'une valeur à zéro

- Une valeur **0** est une mesure reçue (ex. CPU à 0 %) ; une **absence** est un trou dans la courbe
  et « No data » dans un panneau instantané.
- La métrique `up` est produite par **Prometheus lui-même** à chaque collecte : elle vaut 0 quand
  la collecte échoue, même si la cible ne renvoie plus rien. Le panneau « Disponibilité » et
  l'alerte `HoteInjoignable` reposent sur elle, donc une perte de collecte ne passe jamais pour
  « tout va bien ».
- Les panneaux d'état utilisent des requêtes **instantanées** : une machine disparue n'y laisse pas
  sa dernière valeur verte.

Exemple réel : pendant l'incident H, les courbes de LINUX01 s'interrompent de 23:08 à 23:14 et
`up{instance="LINUX01"}` vaut 0 (preuves `S06_12c`, `S06_15d`, `S06_15e`).

## 4. Alertes

Pas d'Alertmanager dans le labo : **les tests portent sur l'état de l'alerte dans Prometheus et
Grafana** (inactive → pending → firing → inactive), pas sur la réception d'un message.

| Alerte | Condition | Durée | Gravité | Justification du seuil | Première action |
|---|---|---|---|---|---|
| HoteInjoignable | `up == 0` | 1 min | critique | Une collecte ratée peut être un incident réseau passager ; 4 échecs consécutifs ne le sont plus | `ping` puis `curl` du port collecteur depuis OPS01 : délai dépassé = filtrage, refus = collecteur arrêté |
| ServiceLinuxArrete | unité systemd critique non active | 30 s | critique | Un service arrêté = utilisateurs impactés ; 30 s évite l'alerte pendant un simple redémarrage | `systemctl status`, `journalctl -u <service>` sur la machine |
| ServiceWindowsArrete | DNS, NTDS, Netlogon ou WinRM arrêté | 30 s | critique | Ces services portent l'authentification et la résolution de tout le labo | `Get-Service`, journal *System* (ID 7036, 7034) |
| DisqueLinuxPresquePlein | volume > 80 % | 2 min | avertissement | 20 % de marge laissent le temps d'agir avant blocage ; seuil commun avec `verification.yml` (`seuil_disque_pct`) | `df -h`, `du -xh --max-depth=1` sur le volume |
| DisqueWindowsPresquePlein | volume > 80 % | 2 min | avertissement | Idem ; Windows Update exige ≥ 5 Go libres sur C: | `Get-Volume`, nettoyage des mises à jour |
| CpuEleve | CPU > 85 % | 5 min | avertissement | Un pic est normal (mise à jour, Defender) ; seule une charge durable est anormale | Processus les plus consommateurs (`ps --sort=-%cpu`, `Get-Process`) |
| MemoireSaturee | mémoire > 90 % | 5 min | avertissement | Au-delà, le système utilise le swap et ralentit | Processus par mémoire, journal OOM (`journalctl -k`) |

### Tests réalisés

| Alerte | Méthode de test contrôlée | Déclenchement | Retour à la normale | Preuves |
|---|---|---|---|---|
| HoteInjoignable | Suppression de la règle ufw 9100 sur LINUX01 + coupure de la connexion établie (incident H) | pending 23:08:18, firing 23:09:37 | inactive à 23:15:13 après `linux.yml` | `S06_12b`, `S06_12`, `S06_15a`, [incident.md](incident.md) |
| ServiceLinuxArrete | Arrêt de nginx sur LINUX01 (scénario de panne 5) | arrêt 00:24:16, firing 00:24:33 (`nginx.service`, LINUX01) | inactive à 01:03:45 après `linux.yml` | `S04_30b` (Prometheus, Grafana), `S04_30d`, [scenarios-pannes.md](scenarios-pannes.md) |

Les règles sont validées avant déploiement (`promtool check rules` dans `monitoring.yml` et en CI).

## 5. Limites

- Pas de notification (e-mail, messagerie) : il faudrait Alertmanager.
- Rétention Prometheus par défaut (15 jours) : suffisante pour le labo, pas pour un suivi de capacité.
- Les journaux ne sont pas centralisés (pas de Loki) : le diagnostic se fait sur chaque machine.
