# Scénarios de panne contrôlée (support S4, §7.4)

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
