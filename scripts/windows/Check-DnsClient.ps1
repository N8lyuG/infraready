# Check-DnsClient.ps1 - InfraReady, support S4 etape 6 (script fourni par le support, commente).
# Controle NON destructif de l'etat LOCAL du service client DNS Windows (Dnscache).
#   exit 0 = service present et en cours d'execution
#   exit 1 = service introuvable OU arrete
# Limite : un service Dnscache actif ne prouve pas qu'un nom precis se resout (tester Resolve-DnsName).

$serviceName = "Dnscache"

# -ErrorAction SilentlyContinue : si le service n'existe pas, on obtient $null au lieu d'une erreur rouge,
# ce qui permet de traiter le cas proprement ci-dessous.
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if ($null -eq $service) {
    Write-Output "ERREUR : service introuvable : $serviceName"
    exit 1
}

if ($service.Status -eq "Running") {
    Write-Output "OK : le service $serviceName est actif"
    exit 0
}

Write-Output "ERREUR : etat du service $serviceName : $($service.Status)"
exit 1
