#!/usr/bin/env python3
"""Genere monitoring/dashboards/infraready.json (tableau de bord Grafana InfraReady).

Le JSON est genere plutot qu'ecrit a la main : chaque panneau est decrit en quelques lignes,
les identifiants et positions sont calcules, et le fichier reste reproductible.
Usage : python3 scripts/outils/generer_dashboard.py
"""
import json
from pathlib import Path

DS = {"type": "prometheus", "uid": "prometheus-infraready"}
SORTIE = Path(__file__).resolve().parents[2] / "monitoring" / "dashboards" / "infraready.json"
_id = 0


def nid():
    global _id
    _id += 1
    return _id


def cible(expr, legende, ref="A", instant=False):
    """instant=True : valeur actuelle seulement (panneaux d'etat) ; sinon serie sur la periode."""
    return {"datasource": DS, "expr": expr, "legendFormat": legende, "refId": ref,
            "range": not instant, "instant": instant}


def seuils_pct(orange=80, rouge=90):
    return {"mode": "absolute", "steps": [
        {"color": "green", "value": None},
        {"color": "orange", "value": orange},
        {"color": "red", "value": rouge}]}


def courbe(titre, pos, cibles, unite="percent", desc="", maxi=100):
    """Serie temporelle avec la ligne de seuil dessinee (thresholdsStyle)."""
    return {
        "id": nid(), "type": "timeseries", "title": titre, "description": desc,
        "datasource": DS, "gridPos": pos, "targets": cibles,
        "fieldConfig": {"defaults": {
            "unit": unite, "min": 0, "max": maxi, "thresholds": seuils_pct(),
            "custom": {"thresholdsStyle": {"mode": "line+area"}, "lineWidth": 2, "fillOpacity": 10}},
            "overrides": []},
        "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["lastNotNull", "max"]},
                    "tooltip": {"mode": "multi"}},
    }


def stat(titre, pos, cibles, unite="none", mappings=None, seuils=None, desc="", texte=None):
    return {
        "id": nid(), "type": "stat", "title": titre, "description": desc,
        "datasource": DS, "gridPos": pos, "targets": cibles,
        "fieldConfig": {"defaults": {"unit": unite, "mappings": mappings or [],
                                     "thresholds": seuils or seuils_pct()}, "overrides": []},
        "options": {"colorMode": "background", "graphMode": "none", "textMode": "value_and_name",
                    "text": texte or {}, "wideLayout": True,
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
    }


ETAT = [{"type": "value", "options": {
    "0": {"text": "HORS SERVICE", "color": "red", "index": 0},
    "1": {"text": "EN SERVICE", "color": "green", "index": 1}}}]
SEUIL_ETAT = {"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}]}

# Expressions PromQL (Linux = node_exporter, Windows = windows_exporter)
CPU_L = '100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[2m])))'
CPU_W = '100 * (1 - avg by (instance) (rate(windows_cpu_time_seconds_total{mode="idle"}[2m])))'
MEM_L = '100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)'
MEM_W = '100 * (1 - windows_memory_available_bytes / windows_memory_physical_total_bytes)'
DSK_L = '100 * (1 - node_filesystem_avail_bytes{fstype=~"ext4|xfs"} / node_filesystem_size_bytes{fstype=~"ext4|xfs"})'
DSK_W = '100 * (1 - windows_logical_disk_free_bytes{volume=~"[A-Z]:"} / windows_logical_disk_size_bytes{volume=~"[A-Z]:"})'

panneaux = [
    stat("Disponibilite des collecteurs (up)", {"x": 0, "y": 0, "w": 8, "h": 7},
         [cible('up{job=~"node|windows"}', "{{instance}}", instant=True)], mappings=ETAT, seuils=SEUIL_ETAT,
         desc="Metrique 'up' produite par Prometheus lui-meme : 1 si la derniere collecte a reussi."),
    stat("Services critiques", {"x": 8, "y": 0, "w": 16, "h": 7}, [
        cible('node_systemd_unit_state{state="active", name=~"(nginx|ssh|prometheus|grafana-server)[.]service"}',
              "{{instance}} {{name}}", "A", instant=True),
        cible('windows_service_state{state="running", service=~"(?i)(dns|ntds|netlogon|winrm)"}',
              "{{instance}} {{service}}", "B", instant=True)],
         mappings=ETAT, seuils=SEUIL_ETAT, texte={"titleSize": 13, "valueSize": 15},
         desc="Linux : collecteur systemd de node_exporter. Windows : collecteur service de windows_exporter."),
    courbe("CPU utilise (%)", {"x": 0, "y": 7, "w": 12, "h": 10},
           [cible(CPU_L, "{{instance}}", "A"), cible(CPU_W, "{{instance}}", "B")],
           desc="100 - temps idle. Seuil d'alerte CpuEleve : 85 % pendant 5 min."),
    courbe("Memoire utilisee (%)", {"x": 12, "y": 7, "w": 12, "h": 10},
           [cible(MEM_L, "{{instance}}", "A"), cible(MEM_W, "{{instance}}", "B")],
           desc="Linux : MemAvailable (cache recuperable deduit). Seuil d'alerte : 90 %."),
    courbe("Stockage utilise (%)", {"x": 0, "y": 17, "w": 12, "h": 10},
           [cible(DSK_L, "{{instance}} {{mountpoint}}", "A"), cible(DSK_W, "{{instance}} {{volume}}", "B")],
           desc="Seuil d'alerte DisqueLinux/WindowsPresquePlein : 80 % pendant 2 min."),
    {
        "id": nid(), "type": "bargauge", "title": "Remplissage des volumes (seuil 80 %)",
        "datasource": DS, "gridPos": {"x": 12, "y": 17, "w": 12, "h": 10},
        "targets": [cible(DSK_L, "{{instance}} {{mountpoint}}", "A", instant=True),
                    cible(DSK_W, "{{instance}} {{volume}}", "B", instant=True)],
        "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100,
                                     "thresholds": seuils_pct()}, "overrides": []},
        "options": {"displayMode": "gradient", "orientation": "horizontal",
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
    },
    stat("Duree depuis le dernier demarrage", {"x": 0, "y": 27, "w": 12, "h": 5}, [
        cible("time() - node_boot_time_seconds", "{{instance}}", "A", instant=True),
        cible("time() - windows_system_boot_time_timestamp", "{{instance}}", "B", instant=True)],
        unite="s", seuils={"mode": "absolute", "steps": [{"color": "blue", "value": None}]},
        desc="Un redemarrage non planifie se voit ici (valeur remise a zero)."),
    {
        "id": nid(), "type": "alertlist", "title": "Alertes Prometheus",
        "gridPos": {"x": 12, "y": 27, "w": 12, "h": 5},
        "options": {"alertInstanceLabelFilter": "", "dashboardAlerts": False, "groupMode": "default",
                    "maxItems": 10, "sortOrder": 1, "stateFilter": {"firing": True, "pending": True},
                    "viewMode": "list", "datasource": "Prometheus"},
    },
]

tableau = {
    "uid": "infraready-labo", "title": "InfraReady - etat du laboratoire",
    "description": "CPU, memoire, stockage et disponibilite de LINUX01, OPS01 et WIN-DC01 (source : Prometheus sur OPS01).",
    "tags": ["infraready", "linux", "windows"], "timezone": "browser", "editable": False,
    "refresh": "30s", "time": {"from": "now-30m", "to": "now"},
    "schemaVersion": 39, "version": 1, "panels": panneaux, "templating": {"list": []},
    "annotations": {"list": []},
}

SORTIE.parent.mkdir(parents=True, exist_ok=True)
with open(SORTIE, "w", encoding="utf-8", newline="\n") as f:  # LF meme sous Windows (la CI tourne sous Linux)
    f.write(json.dumps(tableau, indent=2, ensure_ascii=False) + "\n")
print(f"{SORTIE} : {len(panneaux)} panneaux")
