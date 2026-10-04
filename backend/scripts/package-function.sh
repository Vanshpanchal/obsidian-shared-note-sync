#!/usr/bin/env bash
# Packages the function for "upload code" in the Appwrite Console.
#   ./backend/scripts/package-function.sh   ->   backend/shared-api.tar.gz
# (Not needed if you deploy from Git or with the Appwrite CLI.)
set -euo pipefail
cd "$(dirname "$0")/.."
tar -czf shared-api.tar.gz -C functions/shared-api \
  --exclude=node_modules --exclude=test --exclude='*.log' \
  package.json package-lock.json src
echo "Wrote backend/shared-api.tar.gz"
tar -tzf shared-api.tar.gz
