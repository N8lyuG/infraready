# Rapport d'incident (tâche H) — métriques de LINUX01 absentes

| Champ | Valeur |
|---|---|
| Date | 2026-11-08, 23:07 → 23:15 (essai 1 : 22:57 → 23:06) |
| Machines | LINUX01 (cible), OPS01 (supervision) |
| Type (liste du sujet) | « absence de métriques d'un hôte » |
| Gravité | Moyenne : le service web fonctionne, mais LINUX01 n'est plus surveillé (une panne réelle passerait inaperçue) |
| Caractère | Contrôlé et réversible : snapshot `03-avant-supervision` + correction par Ansible |
| Impact mesuré | Collecte interrompue de 23:08 à 23:14 environ (≈ 6 min de trou dans les courbes) |
| Détection | Alerte `pending` 22 s après la coupure (23:08:18), `firing` 1 min plus tard |
| Résolution | Correction lancée à 23:14:02, alerte retombée et collecte HTTP 200 à 23:15:13 |

Toutes les étapes sont enchaînées et journalisées par `scripts/linux/deployer-labo.sh incident`
(journaux `S06_10` à `S06_15`).

## Mise en place contrôlée (côté « injecteur »)

Sur LINUX01, suppression de la seule règle qui autorise la collecte, puis coupure de la connexion
déjà ouverte par Prometheus (voir l'essai 1 pour la raison) :

```bash
sudo ufw delete allow from 192.168.50.30 to any port 9100 proto tcp
sudo ss -K -tn state established '( sport = :9100 )' dst 192.168.50.30
```

L'équipe qui diagnostique ne connaît que le symptôme.

### Essai 1 : une fausse piste instructive

Lors du premier essai (22:57), seule la règle a été supprimée. Résultat : **aucune alerte**.
Prometheus voyait toujours LINUX01 `up=1`, alors que :

- un `curl` depuis OPS01 vers `192.168.50.20:9100` dépassait son délai (`curl: (28) Connection timed out`) ;
- `ufw.log` contenait des `[UFW BLOCK] SRC=192.168.50.30 DPT=9100`.

**Explication.** ufw (netfilter) est un pare-feu **à états**. Sa première règle accepte tout paquet
d'une connexion déjà `ESTABLISHED`. Prometheus réutilise la même connexion TCP d'une collecte à
l'autre (keep-alive HTTP) : elle n'a jamais été coupée. Seules les **nouvelles** connexions
(paquets `SYN`) étaient bloquées.

En production, la coupure survient au prochain redémarrage, `ufw reload` ou expiration de la
connexion, parfois des heures après la modification. Le changement fautif et la panne ne sont alors
plus liés dans le temps. Le second essai reproduit cette situation en coupant la connexion établie
(`ss -K`).

_Preuves : S06_11e1, S06_12e1, S06_13e1, S06_12a_grafana_aucun_symptome_connexion_etablie.png_

## 1. Symptôme observé (essai 2)

- Prometheus `/classic/alerts` : `HoteInjoignable` **pending** à 23:08:18 puis **FIRING** pour
  `instance="LINUX01", job="node"` (constaté à 23:09:37).
- Grafana, tableau « InfraReady - etat du laboratoire » : panneau **Disponibilité** → LINUX01
  `HORS SERVICE`, services de LINUX01 absents du panneau « Services critiques », courbes CPU et
  mémoire de LINUX01 interrompues.
- Le site web répond toujours : l'incident ne touche que la supervision.

_Preuves : S06_12_incident_symptome_firing.png, S06_12b_prometheus_alerte_pending.png,
S06_12c_grafana_linux01_hors_service.png_

### Périmètre

| Concerné | Non concerné |
|---|---|
| Supervision de LINUX01 : métriques système et état des services absents de Prometheus et Grafana | Le site web (HTTP 200 depuis le labo), SSH, Ansible |
| Les alertes de LINUX01 (disque, CPU, service arrêté) ne pouvaient plus se déclencher | OPS01 et WIN-DC01, toujours collectés (`up=1`) |
| Utilisateurs : aucun impact direct ; risque = une vraie panne de LINUX01 passerait inaperçue | Les données sur `/srv/infraready` |

## 2. Tests et journaux consultés (du plus général au plus précis)

| # | Question | Commande | Résultat attendu si… | Résultat obtenu |
|---|---|---|---|---|
| 1 | Prometheus voit-il une erreur ? | `/api/v1/alerts`, `/classic/targets` | `context deadline exceeded` = paquets perdus ; `connection refused` = rien n'écoute | `HoteInjoignable` FIRING, `up{instance="LINUX01"} = 0` |
| 2 | La machine est-elle vivante ? | `ping -c 2 192.168.50.20` (OPS01) | réponse = réseau et VM OK | 2/2 reçus, 0,4 ms → **OK** |
| 3 | Le port répond-il depuis OPS01 ? | `curl -m 5 -sS http://192.168.50.20:9100/metrics` | délai dépassé = filtrage | `curl: (28) Connection timed out after 5003 ms` → **KO (filtrage)** |
| 4 | Le collecteur tourne-t-il ? | `systemctl is-active prometheus-node-exporter` (LINUX01) | `active` | `active` → **OK** |
| 5 | Écoute-t-il sur le bon port ? | `ss -ltnp \| grep 9100` | `*:9100` | `LISTEN *:9100 prometheus-node` → **OK** |
| 6 | Répond-il en local ? | `curl -s localhost:9100/metrics \| grep -c ^node_` | nombre > 0 | `530` métriques → **OK** |
| 7 | Le pare-feu filtre-t-il ? | `sudo ufw status verbose` | règle 9100 absente | seules 22/tcp et 80/tcp autorisées, défaut `deny (incoming)` → **règle absente** |
| 8 | Preuve dans les journaux | `sudo grep 'DPT=9100' /var/log/ufw.log \| tail -3` | `[UFW BLOCK] … SRC=192.168.50.30 … DPT=9100` | 3 lignes `[UFW BLOCK] SRC=192.168.50.30 DST=192.168.50.20 … DPT=9100 … SYN` (23:09:00, 23:09:19, 23:09:40) |

Raisonnement : 2 OK + 3 KO ⇒ problème entre le réseau et l'application ; 4-5-6 OK ⇒ l'application
est saine ; 7-8 ⇒ le pare-feu de LINUX01 rejette OPS01. Les tests 4 à 6 éliminent l'hypothèse
« collecteur arrêté » (qui aurait donné `connection refused`, pas un délai dépassé). L'intervalle
d'environ 20 s entre les `[UFW BLOCK]` correspond aux tentatives de collecte de Prometheus.

_Preuves : S06_13a_tests_ping_ok_curl_timeout.png, S06_13c_test_collecteur_sain.png,
S06_13d_test_ufw_cause.png_

## 3. Cause identifiée

La règle `ufw` autorisant `192.168.50.30 → 9100/tcp` a été supprimée sur LINUX01. La politique par
défaut `deny (incoming)` bloque alors silencieusement (DROP, sans réponse) chaque nouvelle connexion
de Prometheus, d'où le délai dépassé plutôt qu'un refus.

## 4. Correction appliquée

On ne recrée pas la règle à la main. On rejoue l'état décrit dans le dépôt, qui est la source de
vérité :

```bash
# OPS01, racine du dépôt
ansible-playbook playbooks/linux.yml --limit linux --check --diff -K   # simulation
ansible-playbook playbooks/linux.yml --limit linux -K                  # application
```

Résultats :

- simulation (23:13:50) : `changed=1`, sur la seule tâche « Autoriser node_exporter depuis OPS01
  seulement » ;
- application (23:14:02) : `ok=8 changed=1 failed=0`.

_Preuves : S06_14a_correction_check_diff.png, S06_14b_correction.png_

## 5. Vérification du retour à la normale

- 23:15:13 : `0 alerte(s) active(s)`, collecte LINUX01 `HTTP 200`.
- `verification.yml --limit supervision` : LINUX01, OPS01 (node et prometheus) et WIN-DC01 **up**,
  `failed=0`.
- Prometheus, graphe `up` : LINUX01 à 0 pendant l'incident puis revenu à 1. L'axe du graphe est
  en UTC : 22:08 à 22:14 UTC correspond à 23:08 à 23:14 heure locale.
- Grafana : LINUX01 `EN SERVICE`, courbes reprises ; le trou dans les courbes mesure la durée
  d'impact.
- 2e lancement de `linux.yml` : `changed=0`. La configuration est de nouveau conforme au dépôt.

_Preuves : S06_15a_retour_normal.png, S06_15b_verification_apres_incident.png,
S06_15d_grafana_retour_normal_trou_visible.png, S06_15e_prometheus_up_linux01_0_puis_1.png_

## 6. Prévention

| Mesure | Effet | État |
|---|---|---|
| Règles de pare-feu uniquement posées par Ansible (`linux.yml`) | Une suppression manuelle est annulée au prochain déploiement ; `--check` la révèle avant | En place |
| `ansible-playbook playbooks/linux.yml --check --diff` planifié (dérive de configuration) | Détecte l'écart sans attendre la coupure de la connexion | Proposé |
| Après tout changement de pare-feu : `verification.yml`, qui ouvre de **nouvelles** connexions | Évite le faux « tout va bien » dû aux connexions déjà établies | En place (procédure) |
| Alerte `HoteInjoignable` (`up == 0` pendant 1 min) | Détection en 1 à 2 min au lieu d'un constat fortuit | En place |
| Contrôle de cohérence en CI (inventaire ↔ cibles Prometheus) | Une cible oubliée ou mal adressée est refusée avant fusion | En place |

## Enseignements

- **Ping OK ≠ service joignable** : ICMP et TCP/9100 sont filtrés séparément.
- **Un pare-feu à états ne coupe pas les connexions existantes** : une règle supprimée peut sembler
  sans effet jusqu'au prochain redémarrage ou rechargement. Après un changement de pare-feu, il faut
  tester une **nouvelle** connexion (`curl` depuis la source), pas seulement regarder la supervision.
- La différence entre *timeout* et *connection refused* oriente immédiatement vers le pare-feu ou
  vers l'application.
- La supervision doit être **elle-même supervisée** : sans l'alerte `HoteInjoignable`, l'absence de
  données ressemble à « rien à signaler ».
- Corriger par Ansible plutôt qu'à la main garantit que la correction est identique à la
  configuration documentée et qu'elle ne sera pas écrasée au prochain déploiement.

Autres incidents diagnostiqués pendant le projet : [scénarios de panne Ansible de la séance 4](scenarios-pannes.md).
