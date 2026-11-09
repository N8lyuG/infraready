# Scénarios de panne contrôlée (support S4, §7.4) et compte rendu de dépannage (étape 8)

Projet Ansible : `~/infraready` sur OPS01 (`inventory.ini`, groupe `linux` = LINUX01 seul, `nginx.yml`, `templates/index.html.j2`, variable `site_message`, page `/var/www/html/index.html`).
Un seul scénario actif à la fois. Sauvegardes de référence : `nginx.yml.etat-initial`, `templates/index.html.j2.etat-initial`.

## Préparation (23/10/2026)

État initial vérifié (preuves `S04_23a/b/c`) : cible unique LINUX01, `ping` pong, syntaxe OK ; sur LINUX01 nginx `active`, `nginx -t` OK, HTTP 200, page « Bienvenue sur le serveur web InfraReady ».

## Scénario 1 — Une variable incorrecte produit un contenu erroné ✅

| Phase | Constat / action | Preuve |
|---|---|---|
| Défaut | `site_message: "MESSAGE-INCORRECT-SCENARIO-1"` (ligne 8 de `nginx.yml`) ; déploiement `failed=0`, page `changed`, handler exécuté | S04_24a |
| Symptôme | nginx `active`, **HTTP 200**, mais `<h1>MESSAGE-INCORRECT-SCENARIO-1</h1>` dans le contenu servi et dans `/var/www/html/index.html` | S04_24b |
| Diagnostic | Service actif : oui · HTTP : oui · fichier conforme au modèle : oui (le modèle affiche `{{ site_message }}`) · **valeur effective attendue : non**. `diff nginx.yml.etat-initial nginx.yml` → `8c8` : seule la ligne 8 diffère | S04_25a |
| Cause | Valeur de configuration incorrecte : le service et le déploiement fonctionnent mais publient une valeur fausse | — |
| Correction | Restauration de `nginx.yml` (sûre : le diff prouvait une seule ligne modifiée) ; `--syntax-check`, `--list-hosts`, `--check --diff` (montre `- MESSAGE-INCORRECT…` / `+ Bienvenue…`) puis déploiement réel | S04_25b, S04_25c |
| Vérification | Marqueur absent ; `Bienvenue sur le serveur web InfraReady` de retour | S04_25d |

**Enseignements** : tous les indicateurs techniques (service, HTTP 200, Ansible `failed=0`) peuvent être verts avec un résultat fonctionnel faux. **Le mode `--check` ne modifie rien** : après la seule simulation, LINUX01 servait toujours le message incorrect — seul le contrôle sur la cible prouve la correction.

## Scénario 2 — Le modèle Jinja2 utilise un nom de variable incorrect ✅

| Phase | Constat / action | Preuve |
|---|---|---|
| Défaut | `{{ site_messsage }}` (3 « s ») ligne 5 de `templates/index.html.j2` | S04_26_1 |
| Symptôme | Tâche « Deployer la page du site » **FAILED** : `AnsibleUndefinedVariable: 'site_messsage' is undefined` ; `failed=1 changed=0` | S04_26_1 |
| Preuves | `grep -A5 -B5` : le playbook définit `site_message` (ligne 8), le modèle demande `site_messsage` (ligne 5). Page servie **intacte** (`Bienvenue…`) : le rendu a échoué sur OPS01 avant toute copie | S04_26_2, S04_26c |
| Cause | Le modèle référence une variable inexistante | — |
| Correction | Restauration du modèle (`diff` vide), `--syntax-check`, déploiement : `failed=0 changed=0` (page générée identique à celle en place) | S04_26d |

**Enseignements** : défaut *bruyant* (Ansible bloque) contrairement au scénario 1 *silencieux* ; l'échec du rendu protège le service en production. Incident annexe : relance `-vv` en échec « Incorrect sudo password » (faute de frappe sur `-K`) — distinguer une erreur d'authentification d'une erreur du playbook.

## Scénario 3 — Le modèle est déployé au mauvais chemin ✅

| Phase | Constat / action | Preuve |
|---|---|---|
| Référence | Sur LINUX01 : `/tmp/ir-index.html` absent ; `/var/www/html/index.html` 298 octets, modifié le 23/10 à **14:55:05.866** ; page servie « Bienvenue… » | S04_27a (référence) |
| Défaut | Playbook et modèle identiques à l'état initial avant modification. `sed` sur la ligne 21 de `nginx.yml` : `dest: /tmp/ir-index.html`. `diff` → `21c21` ; `--syntax-check` OK (erreur de sens, pas de syntaxe) | S04_27a (défaut) |
| Déploiement | « Deployer la page du site » **changed** + handler « Recharger nginx » exécuté ; `ok=5 changed=2 failed=0` | S04_27b |
| Symptôme | `/tmp/ir-index.html` créé à **15:34:05** ; la vraie page est **inchangée** (toujours 14:55:05.866) ; nginx `active`, « Bienvenue » servi ; `diff` des deux fichiers : **identiques** → panne **latente**, invisible tant que le contenu ne change pas | S04_27c |
| Diagnostic | Nginx : `sites-enabled/default` → `root /var/www/html;` (fichier l. 41, confirmé dans la configuration chargée par `nginx -T`). Ansible : `dest: /tmp/ir-index.html` (l. 21). `diff` → seule la ligne 21 diffère. **2e lancement sans correction : `ok=4 changed=0`** | S04_28a, S04_28b |
| Cause | Destination du modèle hors de la racine web servie par Nginx | — |
| Correction | Restauration de `nginx.yml` depuis la sauvegarde (`diff` vide, l. 21 = `/var/www/html/index.html`), `--syntax-check`, `--check --diff` (`changed=0`). 1er déploiement réel en échec « Incorrect sudo password » à Gathering Facts (saisie `-K`, aucune tâche exécutée) ; relancé : `ok=4 changed=0 failed=0` | S04_28c (essais 1 et 2) |
| Nettoyage / vérification | `sudo rm -v /tmp/ir-index.html` (artefact orphelin : plus décrit par le playbook, Ansible ne l'aurait jamais supprimé). Vraie page toujours datée 14:55:05.866, « Bienvenue » servi, nginx `active` | S04_28d |

**Enseignements** :
- **Idempotent ≠ correct** : au 2e lancement avec le défaut, Ansible répond `changed=0`. Il maintient fidèlement un état faux. Un `changed=0` prouve la stabilité, pas la conformité fonctionnelle.
- Le module `template` vérifie la destination qu'on lui donne, pas ce que le service lit. Le handler suit la tâche (`changed`), pas l'effet réel sur le service : Nginx a été rechargé pour rien.
- Panne ni vue ni signalée : seuls l'horodatage (`ls --time-style=full-iso`) et la comparaison avec la configuration du service (`root`) la révèlent. D'où l'intérêt d'un contrôle fonctionnel automatique après déploiement (scénario 6).
- Après une correction, il faut supprimer à la main ce que l'erreur a créé et noter ce nettoyage.

## Scénarios 4 à 6 (09/11/2026, dépôt restructuré)

Depuis S5, le projet est le dépôt `infraready` : `playbooks/linux.yml` remplace `nginx.yml`. Les
défauts sont injectés dans une **copie jetable** du dépôt sur OPS01 (`~/infraready-scenarios`,
supprimée à la fin) : le dépôt réel n'est jamais modifié. Étapes rejouables :
`bash scripts/linux/deployer-labo.sh sc4 sc5 sc5_correction sc6` (journaux `S04_29` à `S04_31`).

## Scénario 4 — Un handler n'est pas notifié ✅

Support : un fichier de configuration Nginx `/etc/nginx/conf.d/infraready-version.conf` ajoute
l'en-tête HTTP `X-InfraReady-Version`. Le playbook `sc4.yml` le dépose et notifie `Recharger nginx`.

| Phase | Constat / action | Preuve |
|---|---|---|
| Référence | `version_site=v1` : `changed=2` (fichier + handler) ; `curl -sI` → `X-InfraReady-Version: v1` | S04_29a |
| Défaut | Ligne `notify: Recharger nginx` retirée (`diff` → `15d14`) ; déploiement de `v2` : `changed=1`, **aucun handler**, `failed=0` | S04_29b |
| Symptôme | 00:24:03 : le serveur sert toujours `v1` | S04_29c |
| Diagnostic | Sur disque : `v2` ; `nginx -T` (relit le disque) : `v2` ; dernier `Reloaded nginx.service` du journal **antérieur** à la modification du fichier → le processus en service utilise l'ancienne configuration | S04_29c |
| Correction 1 (insuffisante) | `notify` remis (`diff` vide) et playbook relancé : `changed=0` → **le handler ne se déclenche pas** (il ne réagit qu'à un changement), toujours `v1` | S04_29e |
| Correction 2 | Rechargement explicite `ansible linux -b -m service -a "name=nginx state=reloaded"` → `v2` servi | S04_29e |
| Nettoyage | Fichier de test supprimé + rechargement → plus d'en-tête ; site HTTP 200 | S04_29e |

**Enseignements** :
- Un fichier de configuration à jour sur le disque ne prouve pas que le service l'utilise : il faut
  comparer la **date du dernier rechargement** à la date du fichier, et tester le comportement servi.
- Un oubli de `notify` ne se rattrape pas en remettant `notify` : le changement est déjà appliqué, la
  tâche répond `ok`, le handler ne part pas. Il faut recharger explicitement (ou utiliser
  `--force-handlers` lors du passage fautif).
- L'écart d'environ 2 s observé entre les horloges d'OPS01 et de LINUX01 rappelle la limite « pas de
  NTP centralisé » : corréler les journaux de deux machines demande une source de temps commune.

## Scénario 5 — Le service Nginx est arrêté ✅

| Phase | Constat / action | Preuve |
|---|---|---|
| Défaut | 00:24:16 : `ansible linux -b -m service -a "name=nginx state=stopped"` | S04_30a |
| Symptôme | `curl: (7) Failed to connect … Couldn't connect to server` (refus immédiat) ; alerte **`ServiceLinuxArrete` FIRING** (`nginx.service`, LINUX01) ; Grafana : LINUX01 `EN SERVICE` mais `nginx.service` `HORS SERVICE` | S04_30a, S04_30b (Prometheus, Grafana) |
| Diagnostic | `systemctl is-active` → `inactive` ; `status` → `inactive (dead) since 00:24:16` ; journal : `Stopping` / `Stopped nginx.service` (arrêt propre, pas un plantage) ; `ss -ltn` : rien sur le port 80 | S04_30c |
| Cause | Service arrêté (arrêt volontaire tracé dans le journal systemd) | — |
| Correction | `linux.yml` (état `started`) : « Demarrer et activer Nginx » **changed** ; contrôle fonctionnel « Page servie conforme » | S04_30d |
| Vérification | 01:03:45 : HTTP 200, **0 alerte** ; 2e passage `changed=0` | S04_30d, S04_30f |

**Comparaison avec l'incident H** : ici le port **refuse** la connexion (la machine répond « rien
n'écoute ») ; dans l'incident H, le pare-feu **jetait** les paquets (délai dépassé). Le message
d'erreur oriente à lui seul vers l'application ou vers le réseau. La supervision fait la même
distinction : `HoteInjoignable` (collecte perdue) contre `ServiceLinuxArrete` (machine supervisée,
service arrêté).

### Défaut découvert pendant la correction : playbook non rejouable hors ligne

Le premier lancement de la correction (00:26:33) est resté bloqué plus de 20 minutes sur
« Installer Nginx et ufw », puis a échoué : `Failed to update apt cache` (S04_30d0).

- **Cause** : `cache_valid_time: 3600` impose un `apt update` dès que le cache a plus d'une heure.
  La NAT était refermée depuis 23:23 : chaque résolution DNS d'un miroir prenait 20 s (WIN-DC01
  tente de résoudre vers Internet), et le module `apt` réessayait.
- **Correction** (commit `0dfcb3d`) : variable `acces_internet: false` dans `group_vars/all.yml` ;
  `update_cache` et `cache_valid_time` ne s'appliquent qu'avec `-e acces_internet=true` (installations,
  carte NAT branchée). Même traitement dans `monitoring.yml`, téléchargement du MSI compris.
- **Vérification** : relance à 01:02:33 → « Installer Nginx et ufw » `ok` immédiatement, sans réseau.
- **Leçon** : un playbook validé avec Internet peut ne plus être rejouable dans les conditions réelles
  d'exploitation. Le scénario a révélé une dépendance cachée qu'aucun test « vert » n'avait montrée.

## Scénario 6 — Contrôle fonctionnel `uri` + `assert` ✅

Ajout permanent à `playbooks/linux.yml` : après `flush_handlers`, requête HTTP **depuis OPS01**
(comme un utilisateur, à travers le pare-feu), puis `assert` sur la présence de `site_message` dans
la page servie. Ignoré en `--check` (le module `uri` ne s'exécute pas en simulation).

| Phase | Constat / action | Preuve |
|---|---|---|
| Défaut | Même erreur que le scénario 3 : `dest: /tmp/ir-index.html` (`diff` → `31c31`), avec un nouveau message `Version 2 du site InfraReady` | S04_31a |
| Résultat | Page `changed`, handler exécuté… puis **`FAILED`** : « La page servie par LINUX01 ne contient pas 'Version 2 du site InfraReady' : contenu ou chemin de deploiement incorrect » ; `failed=1` | S04_31a |
| Correction | Playbook restauré : `changed=0`, « Page servie conforme (HTTP 200, message attendu present) » ; artefact `/tmp/ir-index.html` supprimé | S04_31b |

**Enseignement** : au scénario 3, le même défaut donnait `failed=0` et passait inaperçu. Avec le
contrôle fonctionnel, Ansible vérifie le **résultat** et plus seulement l'exécution des tâches : la
panne latente devient une erreur visible au moment du déploiement.

## Étape 8 — Compte rendu de dépannage (synthèse)

### Méthode suivie à chaque fois

1. **Référence** connue et prouvée avant le défaut (état initial, horodatages, contenu servi).
2. **Un seul défaut** à la fois, injecté de façon réversible et tracée (`diff` montrant la seule ligne modifiée).
3. **Symptôme** observé du point de vue de l'utilisateur ou de la supervision, avec l'heure.
4. **Tests du plus général au plus précis** : service actif ? port à l'écoute ? réponse HTTP ? contenu ? configuration lue ? journaux ?
5. **Cause** formulée à partir des preuves, en distinguant fait et hypothèse.
6. **Correction par le dépôt** (source de vérité), précédée de `--syntax-check` et `--check --diff`.
7. **Vérification** par le test fonctionnel initial, puis 2e passage `changed=0`.
8. **Nettoyage** de ce que l'erreur a laissé, et trace dans le journal de changements.

### Tableau récapitulatif

| # | Défaut | Ce qu'Ansible a affiché | Symptôme réel | Indice décisif | Correction |
|---|---|---|---|---|---|
| 1 | Variable `site_message` fausse | `failed=0`, page `changed` | Contenu servi faux, HTTP 200 | `diff` avec l'état initial (une ligne) | Restauration, redéploiement |
| 2 | Variable mal orthographiée dans le modèle | `FAILED` (`AnsibleUndefinedVariable`) | Aucun (page intacte) | Message d'erreur explicite + `grep` | Modèle restauré |
| 3 | Mauvais chemin de destination | `failed=0`, puis `changed=0` | Aucun tant que le contenu ne change pas (panne latente) | Horodatage de la vraie page + `root` de Nginx | Restauration + suppression de l'artefact |
| 4 | Handler non notifié | `failed=0`, pas de handler | Ancienne configuration servie | Date du dernier rechargement < date du fichier | Rechargement explicite |
| 5 | Service arrêté | (détecté par la supervision) | Connexion refusée, alerte `ServiceLinuxArrete` | `systemctl status` + journal `Stopped` | `linux.yml` (état `started`) |
| 6 | Mauvais chemin + contrôle fonctionnel | **`FAILED`** (`assert`) | Détecté au déploiement | Message de l'`assert` | Restauration |
| — | Cache apt hors ligne (découvert) | Bloqué puis `FAILED` | Correction impossible | Processus `apt http` en attente, DNS 20 s | Variable `acces_internet` |

### Conclusions

- **Vert ne veut pas dire correct** : quatre défauts sur six donnaient `failed=0`. Seuls un test
  fonctionnel, la supervision ou la comparaison avec une référence les ont révélés.
- **Un `changed` décrit une action, pas un effet** : handler non déclenché (sc. 4), handler exécuté
  pour rien (sc. 3).
- **Le dépôt est la source de vérité** : chaque correction est un rejeu du playbook, jamais une
  retouche manuelle, et le 2e passage `changed=0` prouve le retour à l'état décrit.
- **Tester dans les conditions réelles d'exploitation** : le labo hors ligne a révélé un défaut
  qu'aucun lancement avec Internet n'avait montré.
