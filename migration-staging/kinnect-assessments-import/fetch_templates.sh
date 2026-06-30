#!/usr/bin/env bash
# Download the 4 KINNECT catalog CSVs from S3 to a local folder, overwriting.
#
#   ./fetch_templates.sh [dest_dir]
#
# Examples:
#   ./fetch_templates.sh                 # -> /private/tmp/kinnect
#   ./fetch_templates.sh ~/Downloads/kinnect
#
# Override BUCKET / PREFIX / PROFILE via env if needed.
set -euo pipefail

DEST="${1:-/private/tmp/kinnect}"
BUCKET="${BUCKET:-carelever.uploads.staging}"
PREFIX="${PREFIX:-migrations-monitor/templates}"
PROFILE="${PROFILE:-carelever-staging}"   # AWS named profile (override via PROFILE=…)

mkdir -p "$DEST"
for f in assessments.csv components.csv variations.csv links.csv; do
  aws s3 cp "s3://${BUCKET}/${PREFIX}/${f}" "${DEST}/${f}" --profile "$PROFILE"
done
echo "-> ${DEST}"
