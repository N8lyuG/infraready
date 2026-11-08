#!/usr/bin/env bash
# deployer-labo.sh - InfraReady : enchaine les etapes S5-S6 depuis OPS01 en journalisant chaque sortie.
# Usage (racine du depot, sur OPS01) :  bash scripts/linux/deployer-labo.sh <etape> [<etape>...]
#   etapes : prerequis linux monitoring tableau verification maintenance incident tout
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
        sudo -k; sudo -S -p '' -v < "$SECRETS/ops01" 2>/dev/null && { echo "  -> OK"; break; }
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

AP=(ansible-playbook)
OPS=(--limit supervision --become-password-file "$SECRETS/ops01")
LNX=(--limit linux --become-password-file "$SECRETS/linux01")
WIN=(--limit windows --connection-password-file "$SECRETS/winrm")
ADHOC_LNX=(ansible linux -b --become-password-file "$SECRETS/linux01")

prerequis() {
    etape S05_00_ops01_reseau_nat bash -c 'ip -br address; ip route; curl -sI https://apt.grafana.com | head -1'
    etape S05_00b_linux01_reseau_nat "${ADHOC_LNX[@]}" -m ansible.builtin.shell -a 'ip -br address; curl -sI http://fr.archive.ubuntu.com/ubuntu/ | head -1'
    etape S05_01_ops01_depot git log --oneline --decorate
    etape S05_01b_ops01_collections ansible-galaxy collection install -r requirements.yml
    etape S05_01c_ops01_inventaire ansible-inventory --graph
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

(( $# )) || { sed -n '2,6p' "$0"; exit 1; }
besoin_secrets
for e in "$@"; do
    case $e in
        prerequis|linux|monitoring|tableau|verification|maintenance|incident) $e ;;
        tout) prerequis; linux; monitoring; verification; maintenance ;;
        *) echo "etape inconnue : $e"; exit 1 ;;
    esac
done
echo; echo "TERMINE - journaux dans $JOURNAUX"
