#!/usr/bin/env bash
# Download a Geofabrik OSM extract into routing/data/region.osm.pbf.
# Usage: infra/scripts/download-osm.sh [europe/great-britain/england/greater-london]
set -euo pipefail
REGION="${1:-europe/great-britain/england/greater-london}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/routing/data/region.osm.pbf"
URL="https://download.geofabrik.de/${REGION}-latest.osm.pbf"
mkdir -p "$(dirname "$DEST")"
echo "Downloading $URL -> $DEST"
curl -fL --progress-bar "$URL" -o "$DEST"
echo "Done. Start GraphHopper with: docker compose -f infra/docker-compose.yml --profile routing up graphhopper"
echo "First import builds the graph cache under routing/data/graph-cache (minutes for a city, hours for a country)."
