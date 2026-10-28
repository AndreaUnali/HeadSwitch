#!/usr/bin/env bash
# Crea la repo GitHub (pubblica) con il contenuto di questa cartella e fa il primo push.
# Uso: ./scripts/setup_github.sh [nome-repo]      (per una repo privata: VISIBILITY=private ./scripts/setup_github.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="${1:-HeadSwitch}"
VISIBILITY="${VISIBILITY:-public}"

if ! command -v gh >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install gh
  else
    echo "Installa la GitHub CLI da https://cli.github.com e rilancia questo script."
    exit 1
  fi
fi

gh auth status >/dev/null 2>&1 || gh auth login --web --git-protocol https

[ -d .git ] || { git init -b main && git add -A && git commit -m "Primo commit"; }

gh repo create "$NAME" "--$VISIBILITY" --source=. --remote=origin --push
echo
echo "Repo creata: $(gh repo view --json url -q .url)"
echo "Da ora: ./scripts/update.sh scarica le novità e reinstalla l'app."
