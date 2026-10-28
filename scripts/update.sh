#!/usr/bin/env bash
# Scarica l'ultima versione da GitHub, ricompila e riavvia l'app.
set -euo pipefail
cd "$(dirname "$0")/.."
git pull --ff-only
./scripts/build_app.sh
