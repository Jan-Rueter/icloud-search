#!/bin/bash
# iCloud Drive Metadata Indexer
# Scannt iCloud Drive und erzeugt ~/.icloud_index/index.json
# Findet auch Dateien, die nur in der Cloud liegen (.icloud-Stubs)

ICLOUD_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
INDEX_DIR="$HOME/.icloud_index"
JSON_PATH="$INDEX_DIR/index.json"
LOG_PATH="$INDEX_DIR/indexer.log"

mkdir -p "$INDEX_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_PATH"
}

log "=== iCloud Indexer gestartet ==="

if [ ! -d "$ICLOUD_DIR" ]; then
  log "FEHLER: iCloud Drive Ordner nicht gefunden: $ICLOUD_DIR"
  exit 1
fi

INDEXED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
TMP_JSON=$(mktemp /tmp/icloud_index_XXXXXX.json)
echo '{"indexed_at":"'"$INDEXED_AT"'","files":[' > "$TMP_JSON"

COUNT=0
FIRST=1

json_escape() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'
}

process_file() {
  local filepath="$1"
  local filename
  filename=$(basename "$filepath")
  local folder
  folder=$(dirname "$filepath" | sed "s|$ICLOUD_DIR||" | sed 's|^/||')
  [ -z "$folder" ] && folder="/"

  local is_cloud=0
  local real_name="$filename"
  local ext=""

  if [[ "$filename" == .*.icloud ]]; then
    is_cloud=1
    real_name="${filename:1}"
    real_name="${real_name%.icloud}"
    ext="${real_name##*.}"
    [ "$ext" = "$real_name" ] && ext=""
  else
    ext="${filename##*.}"
    [ "$ext" = "$filename" ] && ext=""
  fi

  local size=0
  local modified=""
  if [ -f "$filepath" ]; then
    size=$(stat -f%z "$filepath" 2>/dev/null || echo 0)
    modified=$(stat -f"%Sm" -t "%Y-%m-%d %H:%M:%S" "$filepath" 2>/dev/null || echo "")
  fi

  local name_j; name_j=$(json_escape "$real_name")
  local path_j; path_j=$(json_escape "$filepath")
  local folder_j; folder_j=$(json_escape "$folder")
  local ext_j; ext_j=$(json_escape "$ext")
  local mod_j; mod_j=$(json_escape "$modified")

  if [ "$FIRST" -eq 1 ]; then
    FIRST=0
  else
    printf ',' >> "$TMP_JSON"
  fi

  printf '{"name":"%s","path":"%s","folder":"%s","extension":"%s","size_bytes":%s,"modified":"%s","is_cloud_only":%s}' \
    "$name_j" "$path_j" "$folder_j" "$ext_j" "$size" "$mod_j" "$is_cloud" >> "$TMP_JSON"

  COUNT=$((COUNT + 1))
  [ $((COUNT % 1000)) -eq 0 ] && log "$COUNT Dateien verarbeitet…"
}

# Normale lokale Dateien
while IFS= read -r -d '' filepath; do
  process_file "$filepath"
done < <(find "$ICLOUD_DIR" \( -name ".*" ! -name "*.icloud" \) -prune -o -type f -print0 2>/dev/null)

# Cloud-only Stubs
while IFS= read -r -d '' filepath; do
  process_file "$filepath"
done < <(find "$ICLOUD_DIR" -name "*.icloud" -type f -print0 2>/dev/null)

echo ']}' >> "$TMP_JSON"
mv "$TMP_JSON" "$JSON_PATH"

log "Fertig: $COUNT Dateien indiziert"
log "Index: $JSON_PATH ($(du -sh "$JSON_PATH" | cut -f1))"
