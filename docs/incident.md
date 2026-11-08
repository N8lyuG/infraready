# Rapport d'incident (tâche H) — métriques de LINUX01 absentes

| Champ | Valeur |
|---|---|
| Date | _à compléter lors de l'exécution_ |
| Machines | LINUX01 (cible), OPS01 (supervision) |
| Type (liste du sujet) | « absence de métriques d'un hôte » |
| Gravité | Moyenne : le service web fonctionne, mais LINUX01 n'est plus surveillé (une panne réelle passerait inaperçue) |
| Caractère | Contrôlé et réversible : snapshot `03-avant-supervision` + correction par Ansible |
| Durée | _détection → retour à la normale : à compléter_ |

## Mise en place contrôlée (côté « injecteur »)

Sur LINUX01, suppression de la seule règle qui autorise la collecte :

```bash
sudo ufw status numbered                       # repérer la règle 9100/tcp ALLOW IN 192.168.50.30
sudo ufw delete allow from 192.168.50.30 to any port 9100 proto tcp
```

L'équipe qui diagnostique ne connaît que le symptôme.

## 1. Symptôme observé

- Grafana, tableau « InfraReady - etat du laboratoire » : panneau **Disponibilité** → LINUX01 `HORS SERVICE`, courbes CPU/mémoire/disque de LINUX01 interrompues.
- Prometheus `/classic/alerts` : `HoteInjoignable` **pending** puis **firing** après 1 min pour `instance="LINUX01", job="node"`.
- Le site web répond toujours (HTTP 200) : l'incident ne touche que la supervision.

_Preuves : S06_xx_grafana_linux01_down.png, S06_xx_prometheus_alerte_firing.png_

## 2. Tests et journaux consultés (du plus général au plus précis)

| # | Question | Commande | Résultat attendu si… | Résultat obtenu |
|---|---|---|---|---|
| 1 | Prometheus voit-il une erreur ? | Prometheus `/classic/targets` | `context deadline exceeded` = paquets perdus ; `connection refused` = rien n'écoute | _…_ |
| 2 | La machine est-elle vivante ? | `ping -c 2 192.168.50.20` (OPS01) | réponse = réseau et VM OK | _…_ |
| 3 | Le port répond-il depuis OPS01 ? | `curl -m 5 -s http://192.168.50.20:9100/metrics \| head -3` | délai dépassé = filtrage | _…_ |
| 4 | Le collecteur tourne-t-il ? | `systemctl is-active prometheus-node-exporter` (LINUX01) | `active` | _…_ |
| 5 | Écoute-t-il sur le bon port ? | `ss -ltnp \| grep 9100` | `*:9100` | _…_ |
| 6 | Répond-il en local ? | `curl -s localhost:9100/metrics \| grep -c ^node_` | nombre > 0 | _…_ |
| 7 | Le pare-feu filtre-t-il ? | `sudo ufw status verbose` | règle 9100 absente | _…_ |
| 8 | Preuve dans les journaux | `sudo grep 'DPT=9100' /var/log/ufw.log \| tail -3` | `[UFW BLOCK] … SRC=192.168.50.30 … DPT=9100` | _…_ |

Raisonnement : 2 OK + 3 KO ⇒ problème entre le réseau et l'application ; 4-5-6 OK ⇒ l'application est saine ; 7-8 ⇒ le pare-feu de LINUX01 rejette OPS01. Les tests 4 à 6 éliminent l'hypothèse « collecteur arrêté » (qui aurait donné `connection refused`, pas un délai dépassé).

## 3. Cause identifiée

_À compléter._ Attendu : la règle `ufw` autorisant `192.168.50.30 → 9100/tcp` a été supprimée ; la politique par défaut `deny (incoming)` bloque alors silencieusement la collecte.

## 4. Correction appliquée

On ne recrée pas la règle à la main. On rejoue l'état décrit dans le dépôt, qui est la source de vérité :

```bash
# OPS01, racine du dépôt
ansible-playbook playbooks/linux.yml --check --diff -K     # montre la règle qui sera rajoutée
ansible-playbook playbooks/linux.yml -K                    # attendu : 1 changed (règle 9100)
```

_Résultat obtenu : à compléter (récap Ansible)._

## 5. Vérification du retour à la normale

- `ansible-playbook playbooks/verification.yml --limit supervision -K` → toutes les cibles `up`.
- Prometheus `/classic/targets` : `node / LINUX01` **UP** ; alerte `HoteInjoignable` revenue à **inactive**.
- Grafana : LINUX01 `EN SERVICE`, courbes reprises (trou visible pendant l'incident = durée d'impact mesurable).
- 2e lancement de `linux.yml` : `changed=0`.

_Preuves : S06_xx_…_

## Enseignements

- **Ping OK ≠ service joignable** : ICMP et TCP/9100 sont filtrés séparément.
- La différence entre *timeout* et *connection refused* oriente immédiatement vers le pare-feu ou vers l'application.
- La supervision doit être **elle-même supervisée** : sans l'alerte `HoteInjoignable`, l'absence de données ressemble à « rien à signaler ».
- Corriger par Ansible plutôt qu'à la main garantit que la correction est identique à la configuration documentée et qu'elle ne sera pas écrasée au prochain déploiement.
- Prévention : contrôle de cohérence en CI (inventaire ↔ cibles Prometheus) et `verification.yml` après toute modification du pare-feu.

Autres incidents diagnostiqués pendant le projet : [scénarios de panne Ansible de la séance 4](scenarios-pannes.md).
