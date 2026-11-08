#!/usr/bin/env bash
# deployer-labo.sh - InfraReady : enchaine les etapes S5-S6 depuis OPS01 en journalisant chaque sortie.
# Usage (racine du depot, sur OPS01) :  bash scripts/linux/deployer-labo.sh <etape> [<etape>...]
#   etapes : prerequis linux monitoring tableau verification maintenance incident pannes fermeture_nat redemarrage tout
# Les mots de passe sont demandes UNE fois, gardes dans des fichiers temporaires en RAM (/dev/shm,
# droits 600) passes a Ansible par --become-password-file / --connection-password-file, puis
# effaces a la sortie du script (trap), meme en cas d'erreur ou de Ctrl-C. Rien n'est ecrit sur disque.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
JOURNAUX="$HOME/infraready-logs"
mkdir -p "$JOURNAUX"

SECRETS=$(mktemp -d /dev/shm/ir.XXXXXX)
chmod 700 "$SECRETS"
trap 'rm -rf "$SECRETS"' EXIT

demander() {   # $1 = invite, $2 = fichier destination
    local mdp
    read -r -s -p "$1 : " mdp; echo
    printf '%s\n' "$mdp" > "$2"; chmod 600 "$2"
}

besoin_secrets() {
    # Chaque secret est verifie aussitot (3 essais) : une faute de frappe ne fait pas echouer
    # le deploiement 10 minutes plus tard.
    if ! ssh-add -l >/dev/null 2>&1; then
        eval "$(ssh-agent -s)" >/dev/null
        ssh-add ~/.ssh/id_ed25519_lab || exit 1
    fi
    local i
    for i in 1 2 3; do
        demander "Mot de passe sudo de nalyug sur OPS01" "$SECRETS/ops01"
        sudo -k
        # SC2024 voulu : la redirection est faite par l'utilisateur, sudo -S lit le mot de passe sur stdin.
        # shellcheck disable=SC2024
        sudo -S -p '' -v < "$SECRETS/ops01" 2>/dev/null && { echo "  -> OK"; break; }
        echo "  -> refuse, recommence"; (( i == 3 )) && exit 1
    done
    for i in 1 2 3; do
        demander "Mot de passe sudo du compte ansible sur LINUX01" "$SECRETS/linux01"
        ansible linux -b --become-password-file "$SECRETS/linux01" -m ansible.builtin.command -a true >/dev/null 2>&1 \
            && { echo "  -> OK"; break; }
        echo "  -> refuse, recommence"; (( i == 3 )) && exit 1
    done
    for i in 1 2 3; do
        demander "Mot de passe WinRM de svc_ansible" "$SECRETS/winrm"
        ansible windows --connection-password-file "$SECRETS/winrm" -m ansible.windows.win_ping >/dev/null 2>&1 \
            && { echo "  -> OK"; break; }
        echo "  -> refuse, recommence"; (( i == 3 )) && exit 1
    done
}

# etape <nom-journal> <commande...> : affiche, execute, journalise ; s'arrete au premier echec
etape() {
    local nom=$1; shift
    local journal="$JOURNAUX/$nom.log"
    {
        printf '\n===== %s | %s@%s | %s\n$ %s\n' "$nom" "$USER" "$(hostname)" "$(date '+%F %T')" "$*"
    } | tee "$journal"
    "$@" 2>&1 | sed -u "s#$SECRETS#/dev/shm/***#g" | tee -a "$journal"
    local rc=${PIPESTATUS[0]}
    printf '===== fin %s : code retour %s\n' "$nom" "$rc" | tee -a "$journal"
    if (( rc != 0 )); then echo "ARRET : etape $nom en echec (journal : $journal)"; exit "$rc"; fi
}

AP=(ansible-playbook --timeout 30)   # 30 s : laisse a sudo le temps de repondre sur une VM chargee
OPS=(--limit supervision --become-password-file "$SECRETS/ops01")
LNX=(--limit linux --become-password-file "$SECRETS/linux01")
WIN=(--limit windows --connection-password-file "$SECRETS/winrm")
ADHOC_LNX=(ansible linux -b --timeout 30 --become-password-file "$SECRETS/linux01")

prerequis() {
    etape S05_00_ops01_reseau_nat bash -c 'ip -br address; ip route; curl -sI https://apt.grafana.com | head -1'
    etape S05_00b_linux01_reseau_nat "${ADHOC_LNX[@]}" -m ansible.builtin.shell -a 'ip -br address; curl -sI http://fr.archive.ubuntu.com/ubuntu/ | head -1'
    etape S05_01_ops01_depot git log --oneline --decorate
    etape S05_01b_ops01_collections ansible-galaxy collection install -r requirements.yml
    etape S05_01c_ops01_inventaire ansible-inventory --graph
    # SC2016 voulu : $pb doit etre developpe par le bash -c interieur, pas ici.
    # shellcheck disable=SC2016
    etape S05_01d_ops01_syntaxe bash -c 'for pb in playbooks/*.yml; do ansible-playbook "$pb" --syntax-check || exit 1; done'
}

linux() {
    etape S05_02a_linux_check_diff "${AP[@]}" playbooks/linux.yml "${LNX[@]}" --check --diff
    etape S05_02b_linux_1er_passage "${AP[@]}" playbooks/linux.yml "${LNX[@]}"
    etape S05_02c_linux_2e_passage "${AP[@]}" playbooks/linux.yml "${LNX[@]}"
    etape S05_03_linux01_ufw_status "${ADHOC_LNX[@]}" -m ansible.builtin.command -a 'ufw status verbose'
}

monitoring() {
    etape S05_04a_monitoring_ops01 "${AP[@]}" playbooks/monitoring.yml "${OPS[@]}"
    etape S05_04b_monitoring_linux01 "${AP[@]}" playbooks/monitoring.yml "${LNX[@]}"
    etape S05_04c_monitoring_win-dc01 "${AP[@]}" playbooks/monitoring.yml "${WIN[@]}"
    etape S05_05a_monitoring_2e_ops01 "${AP[@]}" playbooks/monitoring.yml "${OPS[@]}"
    etape S05_05b_monitoring_2e_linux01 "${AP[@]}" playbooks/monitoring.yml "${LNX[@]}"
    etape S05_05c_monitoring_2e_win-dc01 "${AP[@]}" playbooks/monitoring.yml "${WIN[@]}"
}

tableau() {   # redeploie seulement la partie OPS01 (tableau de bord, config Prometheus/Grafana)
    etape S06_03_tableau_de_bord_ops01 "${AP[@]}" playbooks/monitoring.yml "${OPS[@]}"
}

verification() {
    etape S06_05a_verification_ops01 "${AP[@]}" playbooks/verification.yml "${OPS[@]}"
    etape S06_05b_verification_linux01 "${AP[@]}" playbooks/verification.yml "${LNX[@]}"
    etape S06_05c_verification_win-dc01 "${AP[@]}" playbooks/verification.yml "${WIN[@]}"
    etape S06_05d_prometheus_cibles bash -c "curl -s localhost:9090/api/v1/targets | python3 -c 'import sys,json; [print(t[\"labels\"][\"job\"], t[\"labels\"][\"instance\"], t[\"health\"], t[\"scrapeUrl\"]) for t in json.load(sys.stdin)[\"data\"][\"activeTargets\"]]'"
}

maintenance() {
    etape S06_07a_maintenance_linux01 "${AP[@]}" playbooks/maintenance.yml "${LNX[@]}"
    etape S06_07b_maintenance_ops01 "${AP[@]}" playbooks/maintenance.yml "${OPS[@]}"
    etape S06_07c_maintenance_win-dc01 "${AP[@]}" playbooks/maintenance.yml "${WIN[@]}"
    etape S06_07d_linux01_journal_maintenance "${ADHOC_LNX[@]}" -m ansible.builtin.command -a 'tail -5 /var/log/infraready-maintenance.log'
}

alertes() {  # etat des alertes Prometheus, lisible
    curl -s localhost:9090/api/v1/alerts | python3 -c 'import sys,json
a=json.load(sys.stdin)["data"]["alerts"]
print(f"{len(a)} alerte(s) active(s)")
[print(x["state"].upper(), x["labels"]["alertname"], x["labels"].get("instance"), x["activeAt"]) for x in a]'
}

incident() {
    etape S06_10_incident_etat_initial bash -c "$(declare -f alertes); alertes; curl -s -o /dev/null -w 'collecte LINUX01 : HTTP %{http_code}\n' -m 5 http://192.168.50.20:9100/metrics"
    etape S06_11_incident_injection "${ADHOC_LNX[@]}" -m ansible.builtin.command -a 'ufw delete allow from 192.168.50.30 to any port 9100 proto tcp'
    # ufw est un pare-feu a etats : la connexion keep-alive deja ouverte par Prometheus reste
    # autorisee (ESTABLISHED) malgre la suppression de la regle. On la coupe, comme le ferait un
    # redemarrage ou un rechargement du pare-feu ; la reconnexion est alors bloquee.
    etape S06_11b_incident_coupure_connexions "${ADHOC_LNX[@]}" -m ansible.builtin.shell -a 'ss -tn state established "( sport = :9100 )"; ss -K -tn state established "( sport = :9100 )" dst 192.168.50.30 >/dev/null; echo "--- apres coupure :"; ss -tn state established "( sport = :9100 )"'
    echo "Attente de 100 s : Prometheus doit constater l'absence de metriques (alerte for: 1m)..."; sleep 100
    etape S06_12_incident_symptome bash -c "$(declare -f alertes); date '+%T'; alertes"
    etape S06_13a_test_ping ping -c 2 192.168.50.20
    etape S06_13b_test_curl_distant bash -c 'curl -m 5 -sS http://192.168.50.20:9100/metrics | head -3; echo "code curl : $?"; true'
    etape S06_13c_test_service_linux01 "${ADHOC_LNX[@]}" -m ansible.builtin.shell -a 'systemctl is-active prometheus-node-exporter; ss -ltnp | grep 9100; curl -s localhost:9100/metrics | grep -c "^node_"'
    etape S06_13d_test_ufw_linux01 "${ADHOC_LNX[@]}" -m ansible.builtin.shell -a 'ufw status verbose; echo ---; grep "DPT=9100" /var/log/ufw.log | tail -3'
    echo "PAUSE 240 s pour les captures Grafana / Prometheus pendant l'incident..."; sleep 240
    etape S06_14a_correction_check_diff "${AP[@]}" playbooks/linux.yml "${LNX[@]}" --check --diff
    etape S06_14b_correction "${AP[@]}" playbooks/linux.yml "${LNX[@]}"
    echo "Attente de 60 s : reprise de la collecte..."; sleep 60
    etape S06_15a_retour_normal bash -c "$(declare -f alertes); date '+%T'; alertes; curl -s -o /dev/null -w 'collecte LINUX01 : HTTP %{http_code}\n' -m 5 http://192.168.50.20:9100/metrics"
    etape S06_15b_retour_normal_verification "${AP[@]}" playbooks/verification.yml "${OPS[@]}"
    etape S06_15c_correction_2e_passage "${AP[@]}" playbooks/linux.yml "${LNX[@]}"
}

# ---------------------------------------------------------------------------------------------
# Scenarios de panne 4 a 6 (S4 §7.4). Les defauts sont injectes dans une COPIE JETABLE du depot
# ($SC) : le depot reel n'est jamais modifie. Un seul scenario actif a la fois.
SC="$HOME/infraready-scenarios"
SITE=http://192.168.50.20/
LNXS="${LNX[*]}"   # forme texte pour les commandes passees a bash -c

pannes() {
    rm -rf "$SC" && cp -r . "$SC"
    cat > "$SC/playbooks/sc4.yml" <<'EOF'
---
- name: Scenario 4 - en-tete HTTP de version (fichier de configuration Nginx)
  hosts: linux
  become: true
  vars:
    version_site: v1
  tasks:
    - name: Deployer l'en-tete de version
      ansible.builtin.copy:
        dest: /etc/nginx/conf.d/infraready-version.conf
        content: "add_header X-InfraReady-Version \"{{ version_site }}\" always;\n"
        owner: root
        group: root
        mode: "0644"
      notify: Recharger nginx
  handlers:
    - name: Recharger nginx
      ansible.builtin.service:
        name: nginx
        state: reloaded
EOF
    local entete="curl -sI $SITE | grep -i -e '^HTTP' -e '^x-infraready' || echo '(aucun en-tete X-InfraReady-Version)'"
    # --- Scenario 4 : handler non notifie
    etape S04_29a_sc4_reference bash -c "cd $SC && ${AP[*]} playbooks/sc4.yml $LNXS -e version_site=v1 && date +%T && $entete"
    etape S04_29b_sc4_defaut bash -c "cd $SC && cp playbooks/sc4.yml playbooks/sc4.yml.ref && sed -i '/notify: Recharger nginx/d' playbooks/sc4.yml && { diff playbooks/sc4.yml.ref playbooks/sc4.yml; ${AP[*]} playbooks/sc4.yml $LNXS -e version_site=v2; }"
    etape S04_29c_sc4_symptome bash -c "date +%T; echo '--- en-tete servi (vu depuis OPS01) :'; $entete"
    etape S04_29d_sc4_diagnostic "${ADHOC_LNX[@]}" -m ansible.builtin.shell -a 'echo "--- fichier sur disque :"; cat /etc/nginx/conf.d/infraready-version.conf; echo "--- configuration lue sur disque (nginx -T) :"; nginx -T 2>/dev/null | grep X-InfraReady; echo "--- dates :"; stat -c "fichier modifie : %y" /etc/nginx/conf.d/infraready-version.conf; journalctl -u nginx --since "-20 min" --no-pager -o short-iso | grep -i reload | tail -3; true'
    etape S04_29e_sc4_correction_insuffisante bash -c "cd $SC && cp playbooks/sc4.yml.ref playbooks/sc4.yml && diff playbooks/sc4.yml.ref playbooks/sc4.yml && ${AP[*]} playbooks/sc4.yml $LNXS -e version_site=v2 && $entete"
    etape S04_29f_sc4_correction "${ADHOC_LNX[@]}" -m ansible.builtin.service -a 'name=nginx state=reloaded'
    etape S04_29g_sc4_verification bash -c "$entete"
    etape S04_29h_sc4_nettoyage bash -c "${ADHOC_LNX[*]} -m ansible.builtin.file -a 'path=/etc/nginx/conf.d/infraready-version.conf state=absent' && ${ADHOC_LNX[*]} -m ansible.builtin.service -a 'name=nginx state=reloaded' && $entete"

    # --- Scenario 5 : service Nginx arrete
    etape S04_30a_sc5_injection "${ADHOC_LNX[@]}" -m ansible.builtin.service -a 'name=nginx state=stopped'
    echo "Attente de 75 s : alerte ServiceLinuxArrete (for: 30s)..."; sleep 75
    etape S04_30b_sc5_symptome bash -c "$(declare -f alertes); date '+%T'; curl -sS -m 5 $SITE; echo \"code curl : \$?\"; alertes"
    etape S04_30c_sc5_diagnostic "${ADHOC_LNX[@]}" -m ansible.builtin.shell -a 'systemctl is-active nginx; systemctl status nginx --no-pager -l | head -4; echo "--- journal :"; journalctl -u nginx -n 4 --no-pager -o short-iso; echo "--- ports en ecoute :"; ss -ltn | grep -E ":80 " || echo "rien n ecoute sur le port 80"'
    echo "PAUSE 60 s pour les captures (alerte ServiceLinuxArrete)..."; sleep 60
    etape S04_30d_sc5_correction "${AP[@]}" playbooks/linux.yml "${LNX[@]}"
    echo "Attente de 60 s : retour de l'alerte a l'etat inactif..."; sleep 60
    etape S04_30e_sc5_retour_normal bash -c "$(declare -f alertes); date '+%T'; curl -s -o /dev/null -w 'site : HTTP %{http_code}\n' $SITE; alertes"
    etape S04_30f_sc5_2e_passage "${AP[@]}" playbooks/linux.yml "${LNX[@]}"

    # --- Scenario 6 : le controle fonctionnel detecte la panne latente du scenario 3
    etape S04_31a_sc6_defaut_detecte bash -c "cd $SC && cp playbooks/linux.yml playbooks/linux.yml.ref && sed -i 's#dest: /var/www/html/index.html#dest: /tmp/ir-index.html#' playbooks/linux.yml && { diff playbooks/linux.yml.ref playbooks/linux.yml; ${AP[*]} playbooks/linux.yml $LNXS -e 'site_message=\"Version 2 du site InfraReady\"' || echo \"ECHEC ATTENDU : le controle fonctionnel a detecte la panne (code \$?)\"; }"
    etape S04_31b_sc6_correction bash -c "cd $SC && cp playbooks/linux.yml.ref playbooks/linux.yml && diff playbooks/linux.yml.ref playbooks/linux.yml && ${AP[*]} playbooks/linux.yml $LNXS && ${ADHOC_LNX[*]} -m ansible.builtin.file -a 'path=/tmp/ir-index.html state=absent'"
    rm -rf "$SC"
}

fermeture_nat() {   # retire la configuration netplan de la carte NAT (deja deconnectee dans VMware)
    etape S06_16c_netplan_linux01 "${ADHOC_LNX[@]}" -m ansible.builtin.shell -a 'rm -fv /etc/netplan/90-nat-temporaire.yaml && netplan generate && netplan apply && ls /etc/netplan && ip -br address && ip route'
    etape S06_16d_netplan_ops01 ansible supervision -b --timeout 30 --become-password-file "$SECRETS/ops01" -m ansible.builtin.shell -a 'rm -fv /etc/netplan/90-nat-temporaire.yaml && netplan generate && netplan apply && ls /etc/netplan && ip -br address && ip route'
}

redemarrage() {     # noyau mis a jour pendant la maintenance : redemarrage encadre de LINUX01
    etape S06_17a_redemarrage_linux01 "${AP[@]}" playbooks/maintenance.yml "${LNX[@]}" -e autoriser_redemarrage=true
    etape S06_17b_verification_linux01 "${AP[@]}" playbooks/verification.yml "${LNX[@]}"
    etape S06_17c_linux01_uptime "${ADHOC_LNX[@]}" -m ansible.builtin.shell -a 'uptime; uname -r; ls /var/run/reboot-required 2>/dev/null || echo "aucun redemarrage requis"; findmnt /srv/infraready'
}

(( $# )) || { sed -n '2,6p' "$0"; exit 1; }
besoin_secrets
for e in "$@"; do
    case $e in
        prerequis|linux|monitoring|tableau|verification|maintenance|incident|pannes|fermeture_nat|redemarrage) $e ;;
        tout) prerequis; linux; monitoring; verification; maintenance ;;
        *) echo "etape inconnue : $e"; exit 1 ;;
    esac
done
echo; echo "TERMINE - journaux dans $JOURNAUX"
