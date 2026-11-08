#!/usr/bin/env bash
# check-nginx.sh - InfraReady, support S4 etape 6 (script fourni par le support, commente).
# Controle NON destructif : verifie que le service nginx est actif, affiche un message
# lisible et renvoie un code de sortie exploitable par un outil de supervision ou un script.
#   code 0 = controle positif (service actif)
#   code 1 = controle negatif (service inactif OU absent)
# Le script ne redemarre jamais le service : il constate, il ne corrige pas.

set -u                      # erreur si une variable non definie est utilisee (evite les fautes de frappe silencieuses)

SERVICE="nginx"             # service a controler ; une variable = une seule valeur a modifier

# systemctl is-active --quiet : n'affiche rien, renvoie 0 si l'unite est "active", autre chose sinon
if systemctl is-active --quiet "$SERVICE"; then
    echo "OK : le service $SERVICE est actif"
    exit 0
else
    echo "ERREUR : le service $SERVICE n'est pas actif"
    exit 1
fi
