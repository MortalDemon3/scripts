#!/usr/bin/env bash
# DESC: Une ligne qui décrit le script (affichée sur get.andries.icu)
#
# Usage :
#   curl -fsSL https://get.andries.icu/<dossier>/<nom> | bash
#   curl -fsSL https://get.andries.icu/<dossier>/<nom> | bash -s -- --yes
#
# Modèle : copier ce fichier dans un dossier (pve/, debian/, docker/...),
# le renommer, remplir main(). Le script doit rester autonome
# (pas de "source" d'un autre fichier) pour fonctionner via curl | bash.
set -euo pipefail

if [ -t 1 ]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_BLUE=$'\e[34m'
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
else
  C_RESET=''; C_BOLD=''; C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''
fi
info() { printf '%s[i]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[✗]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage : ... | bash -s -- [options]
  -y, --yes   Non interactif
  -h, --help  Aide
EOF
}

# Lecture au clavier via /dev/tty (stdin est occupé par curl | bash)
ask() {
  local q="$1" def="${2:-y}" ans="" prompt
  if [ "$ASSUME_YES" -eq 1 ]; then [ "$def" = y ] && return 0 || return 1; fi
  if [ "$def" = y ]; then prompt="[O/n]"; else prompt="[o/N]"; fi
  read -r -p "$q $prompt " ans < /dev/tty 2>/dev/null || ans=""
  ans="${ans:-$def}"
  case "${ans,,}" in o|oui|y|yes) return 0 ;; *) return 1 ;; esac
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes)  ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *)         die "Option inconnue : $1" ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  [ "$(id -u)" -eq 0 ] || die "À lancer en root."

  step "Étape 1"
  # ... ton code ici ...
  ok "Fini."
}

# Appel en dernière ligne : si le téléchargement est coupé, rien ne s'exécute
main "$@"
