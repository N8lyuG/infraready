#!/usr/bin/env python3
"""Controle de coherence du depot InfraReady (execute par la CI a chaque push).

Verifie que les fichiers qui decrivent la meme infrastructure ne se contredisent pas :
  1. chaque machine de l'inventaire est supervisee par Prometheus, avec la meme adresse IP ;
  2. les ports de collecte de prometheus.yml sont ceux declares dans group_vars/all.yml ;
  3. le tableau de bord Grafana utilise la source de donnees provisionnee ;
  4. chaque playbook cite dans le README existe ;
  5. aucun fichier versionne ne ressemble a une cle privee ou a un coffre Ansible Vault en clair.
Code de sortie : 0 si tout est coherent, 1 sinon (la CI echoue).
"""
import json
import re
import sys
from pathlib import Path

import yaml

RACINE = Path(__file__).resolve().parents[2]
erreurs = []


def charger(chemin):
    return yaml.safe_load((RACINE / chemin).read_text(encoding="utf-8"))


def hotes(noeud):
    """Parcourt l'arbre de l'inventaire YAML et renvoie {nom: variables}."""
    res = dict(noeud.get("hosts") or {})
    for enfant in (noeud.get("children") or {}).values():
        res.update(hotes(enfant or {}))
    return res


inventaire = hotes(charger("inventory/hosts.yml")["all"])
variables = charger("inventory/group_vars/all.yml")
prom = charger("monitoring/prometheus.yml")

# 1 et 2 : inventaire <-> cibles Prometheus
cibles = []  # (instance, job, cible) : une machine peut etre collectee par plusieurs jobs
for job in prom["scrape_configs"]:
    for sc in job["static_configs"]:
        for cible in sc["targets"]:
            cibles.append((sc["labels"]["instance"], job["job_name"], cible))

ports = {"node": variables["port_node_exporter"], "windows": variables["port_windows_exporter"]}
for nom, hv in inventaire.items():
    collecte = [(j, c) for (n, j, c) in cibles if n == nom and j in ports]
    if not collecte:
        erreurs.append(f"{nom} est dans l'inventaire mais n'est collecte par aucun job node/windows")
        continue
    job, cible = collecte[0]
    hote, port = cible.rsplit(":", 1)
    if int(port) != ports[job]:
        erreurs.append(f"{nom} : port {port} dans prometheus.yml, {ports[job]} attendu (group_vars)")
    local = hv.get("ansible_connection") == "local"
    if not local and hote != hv["ansible_host"]:
        erreurs.append(f"{nom} : IP {hote} dans prometheus.yml, {hv['ansible_host']} dans l'inventaire")

# 3 : tableau de bord <-> source de donnees
ds = charger("monitoring/grafana/provisioning/datasources/prometheus.yml")["datasources"][0]["uid"]
for f in (RACINE / "monitoring/dashboards").glob("*.json"):
    uids = set(re.findall(r'"uid":\s*"([^"]+)"', f.read_text(encoding="utf-8"))) - {json.loads(f.read_text(encoding="utf-8"))["uid"]}
    if uids != {ds}:
        erreurs.append(f"{f.name} : sources {uids}, attendu {{'{ds}'}}")

# 4 : README <-> playbooks
readme = (RACINE / "README.md").read_text(encoding="utf-8")
for pb in sorted(set(re.findall(r"playbooks/[\w-]+\.yml", readme))):
    if not (RACINE / pb).exists():
        erreurs.append(f"README cite {pb} qui n'existe pas")

# 5 : secrets evidents
motifs = [r"-----BEGIN [A-Z ]*PRIVATE KEY-----", r"ansible_(become_)?password\s*[:=]\s*\S+", r"ansible_ssh_pass\s*[:=]"]
for f in RACINE.rglob("*"):
    if f.is_file() and ".git" not in f.parts and f.suffix in {".yml", ".yaml", ".ini", ".cfg", ".md", ".ps1", ".sh", ".j2"}:
        texte = f.read_text(encoding="utf-8", errors="ignore")
        for m in motifs:
            if re.search(m, texte) and "$ANSIBLE_VAULT" not in texte:
                erreurs.append(f"{f.relative_to(RACINE)} : motif sensible '{m}'")

for e in erreurs:
    print(f"ERREUR : {e}")
print(f"{len(inventaire)} machines, {len(cibles)} cibles Prometheus, {len(erreurs)} incoherence(s)")
sys.exit(1 if erreurs else 0)
