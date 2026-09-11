#!/usr/bin/env bash
# Download a Geofabrik OSM extract into routing/data/region.osm.pbf.
# Usage: infra/scripts/download-osm.sh [europe/united-kingdom/england/greater-london]
set -euo pipefail
REGION="${1:-europe/united-kingdom/england/greater-london}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/routing/data/region.osm.pbf"
URL="https://download.geofabrik.de/${REGION}-latest.osm.pbf"
mkdir -p "$(dirname "$DEST")"
echo "Downloading $URL -> $DEST"
curl -fL --progress-bar "$URL" -o "$DEST"
# Geofabrik answers a moved or unknown region with a redirect to its HTML home
# page, which curl happily saves. A real PBF starts with an "OSMHeader" blob.
if ! head -c 64 "$DEST" | grep -aq OSMHeader; then
  rm -f "$DEST"
  echo "Not an OSM PBF: '$REGION' is not a Geofabrik region path (see https://download.geofabrik.de/)." >&2
  exit 1
fi
echo "Done. Start GraphHopper with: docker compose -f infra/docker-compose.yml --profile routing up graphhopper"
echo "First import builds the graph cache under routing/data/graph-cache (minutes for a city, hours for a country)."
