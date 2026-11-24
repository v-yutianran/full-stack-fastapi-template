#!/usr/bin/env bash
# Deployment entrypoint executed by Coolify as the post-deployment command.
# - always runs the template migrations + initial data
# - seeds shared demo data when SEED_DEMO_DATA=true (staging and PR previews)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

bash scripts/prestart.sh

if [ "${SEED_DEMO_DATA:-false}" = "true" ]; then
  echo "SEED_DEMO_DATA=true -> seeding shared demo data"
  PYTHONPATH="$(pwd)" python scripts/seed_demo.py
fi
