<#
.SYNOPSIS
  InfraReady - Seance 3, tache B : structure AD (OU, groupes, comptes de test) + partage de demonstration des droits.
.DESCRIPTION
  A executer sur WIN-DC01, dans PowerShell administrateur (compte INFRAREADY\Administrator).
  Idempotent : chaque objet est cree seulement s'il n'existe pas deja -> le script peut etre rejoue.
  Methode AGDLP : comptes -> groupes globaux (GG_, metier) -> groupes domaine local (DL_, ressource) -> permissions NTFS.
  Aucun mot de passe n'est ecrit dans ce fichier : il est demande a l'execution.
#>
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domainDN = (Get-ADDomain).DistinguishedName          # DC=infraready,DC=test
$ouRoot   = "OU=InfraReady,$domainDN"
$ouUsers  = "OU=Utilisateurs,$ouRoot"
$ouGroups = "OU=Groupes,$ouRoot"
$share    = 'C:\Partages\Docs'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# --- 1. Unites d'organisation -------------------------------------------------
Write-Step 'Unites d organisation'
foreach ($ou in @(@{Name='InfraReady';  Path=$domainDN},
                  @{Name='Utilisateurs';Path=$ouRoot},
                  @{Name='Groupes';     Path=$ouRoot})) {
    $dn = "OU=$($ou.Name),$($ou.Path)"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'")) {
        New-ADOrganizationalUnit -Name $ou.Name -Path $ou.Path -ProtectedFromAccidentalDeletion $true
        Write-Host "   cree   : $dn"
    } else { Write-Host "   existe : $dn" }
}

# --- 2. Groupes (Global = metier, DomainLocal = permission sur une ressource) ----
Write-Step 'Groupes'
$groups = @(
    @{Name='GG_InfraReady_Admins';       Scope='Global';      Desc='Equipe administration systemes'},
    @{Name='GG_InfraReady_Support';      Scope='Global';      Desc='Equipe support / helpdesk'},
    @{Name='GG_InfraReady_Utilisateurs'; Scope='Global';      Desc='Utilisateurs metier'},
    @{Name='DL_Partage_Docs_RW';         Scope='DomainLocal'; Desc='Modification sur \\WIN-DC01\Docs'},
    @{Name='DL_Partage_Docs_RO';         Scope='DomainLocal'; Desc='Lecture seule sur \\WIN-DC01\Docs'}
)
foreach ($g in $groups) {
    if (-not (Get-ADGroup -Filter "Name -eq '$($g.Name)'")) {
        New-ADGroup -Name $g.Name -GroupScope $g.Scope -GroupCategory Security -Path $ouGroups -Description $g.Desc
        Write-Host "   cree   : $($g.Name) ($($g.Scope))"
    } else { Write-Host "   existe : $($g.Name)" }
}

# --- 3. Comptes de test ---------------------------------------------------------
Write-Step 'Comptes de test'
$users = @(
    @{Sam='a.martin';  Given='Alice';  Surname='Martin';  Group='GG_InfraReady_Admins'},
    @{Sam='s.bernard'; Given='Samir';  Surname='Bernard'; Group='GG_InfraReady_Support'},
    @{Sam='u.durand';  Given='Ugo';    Surname='Durand';  Group='GG_InfraReady_Utilisateurs'},
    @{Sam='u.petit';   Given='Ines';   Surname='Petit';   Group='GG_InfraReady_Utilisateurs'}
)
$newUsers = $users | Where-Object { -not (Get-ADUser -Filter "SamAccountName -eq '$($_.Sam)'") }
if ($newUsers) {
    # Mot de passe de TEST commun, saisi a l'execution, jamais stocke (a mettre dans le gestionnaire).
    $mdpTest = Read-Host 'Mot de passe des comptes de test (complexe, 12+ caracteres)' -AsSecureString
}
foreach ($u in $users) {
    if ($newUsers.Sam -contains $u.Sam) {
        New-ADUser -Name "$($u.Given) $($u.Surname)" -GivenName $u.Given -Surname $u.Surname `
            -SamAccountName $u.Sam -UserPrincipalName "$($u.Sam)@infraready.test" `
            -Path $ouUsers -AccountPassword $mdpTest -Enabled $true -Description 'Compte de TEST InfraReady'
        Write-Host "   cree   : $($u.Sam)"
    } else { Write-Host "   existe : $($u.Sam)" }
    Add-ADGroupMember -Identity $u.Group -Members $u.Sam      # sans effet si deja membre
}

# --- 4. AGDLP : groupes globaux -> groupes domaine local -------------------------
Write-Step 'Imbrication AGDLP'
# Choix "option B" (moindre privilege) : le support consulte les procedures mais ne les modifie pas.
Add-ADGroupMember -Identity 'DL_Partage_Docs_RW' -Members 'GG_InfraReady_Admins'
Add-ADGroupMember -Identity 'DL_Partage_Docs_RO' -Members 'GG_InfraReady_Utilisateurs','GG_InfraReady_Support'

# --- 5. Dossier partage + permissions --------------------------------------------
Write-Step 'Dossier partage'
if (-not (Test-Path $share)) { New-Item -ItemType Directory -Path $share | Out-Null }
if (-not (Get-SmbShare -Name 'Docs' -ErrorAction SilentlyContinue)) {
    # Partage large ("Utilisateurs authentifies" en modification) : c'est NTFS qui filtre finement.
    New-SmbShare -Name 'Docs' -Path $share -ChangeAccess 'Authenticated Users' -FullAccess 'Administrators' | Out-Null
    Write-Host '   partage \\WIN-DC01\Docs cree'
} else { Write-Host '   partage Docs existe' }

# Permissions NTFS du dossier $share (icacls). L'ordre compte : on redonne les droits
# d'administration dans la foulee de la coupure d'heritage, sinon le dossier devient inaccessible.
#   1) couper l'heritage en supprimant les droits herites (feuille vierge)
icacls $share /inheritance:r | Out-Null
#   2) controle total aux administrateurs et a SYSTEM
icacls $share /grant "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null
#   3) matrice AGDLP : seuls les groupes DL_ portent des droits ; (OI)(CI) = fichiers et sous-dossiers
icacls $share /grant "INFRAREADY\DL_Partage_Docs_RW:(OI)(CI)M" | Out-Null
icacls $share /grant "INFRAREADY\DL_Partage_Docs_RO:(OI)(CI)RX" | Out-Null

# --- 6. Controle ------------------------------------------------------------------
Write-Step 'Verification'
Get-ADGroupMember 'DL_Partage_Docs_RW' | Select-Object Name, objectClass | Format-Table -AutoSize
Get-ADGroupMember 'DL_Partage_Docs_RO' | Select-Object Name, objectClass | Format-Table -AutoSize
icacls $share
