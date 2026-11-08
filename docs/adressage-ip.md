# Plan d'adressage IP

Réseau du laboratoire : **192.168.50.0/24** (VMnet1, host-only, DHCP VMware désactivé).
Vérifié sans conflit avec les réseaux de l'hôte (Wi-Fi école 10.37.0.0/21, VMnet8 192.168.186.0/24).

| Machine | Interface | Adresse | Passerelle | DNS | Configuration |
|---|---|---|---|---|---|
| Hôte NALYUG | VMware Network Adapter VMnet1 | 192.168.50.1/24 | — | — | Statique (New-NetIPAddress) |
| WIN-DC01 | Ethernet0 (Intel 82574L / e1000e) | 192.168.50.10/24 | aucune | 127.0.0.1 | Statique (New-NetIPAddress) |
| LINUX01 | ens33 | 192.168.50.20/24 | aucune | 192.168.50.10, search infraready.test | Netplan `/etc/netplan/01-lab.yaml` |
| OPS01 | ens33 | 192.168.50.30/24 | aucune | 192.168.50.10, search infraready.test | Netplan `/etc/netplan/01-lab.yaml` |

## DNS (zone `infraready.test`, intégrée AD, sur WIN-DC01)

| Nom | Type | Valeur |
|---|---|---|
| WIN-DC01.infraready.test | A | 192.168.50.10 |
| LINUX01.infraready.test | A (+PTR) | 192.168.50.20 |
| OPS01.infraready.test | A (+PTR) | 192.168.50.30 |
| _ldap._tcp.dc._msdcs.infraready.test | SRV | 0 100 389 win-dc01.infraready.test |

Zone inverse : `50.168.192.in-addr.arpa` (PTR .10, .20, .30).

## Netplan de référence (LINUX01 — `.30` pour OPS01)

```yaml
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: false
      addresses: [192.168.50.20/24]
      nameservers:
        addresses: [192.168.50.10]
        search: [infraready.test]
```

Procédure : sauvegarde `/etc/netplan` → désactivation du réseau cloud-init (`/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`) → retrait de `50-cloud-init.yaml` (fusion alphabétique Netplan) → `chmod 600` → `netplan generate` → `netplan try` (retour automatique en 120 s sans confirmation).
