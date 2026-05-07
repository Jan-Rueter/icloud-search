#!/bin/bash
# iCloud Volltext-Indexer
# Lädt ausgelagerte Dateien temporär herunter, extrahiert Text, lagert sie zurück.
# Verarbeitet lokale Dateien direkt. Arbeitet in Batches mit Größenlimit.
#
# Konfiguration per Umgebungsvariablen oder Standardwerte:
#   BATCH_SIZE_MB   – max. Download-Volumen pro Batch (Standard: 200 MB)
#   BATCH_PAUSE_SEC – Pause zwischen Batches in Sekunden (Standard: 5)
#   MIN_TEXT_BYTES  – Mindestlänge extrahierten Texts (Standard: 50 Zeichen)
#   MAX_TEXT_CHARS  – Max. gespeicherte Zeichen pro Datei (Standard: 50000)
#
# Unterstützte Formate:
#   Text/Code  : txt md rtf sh py js ts css html xml json yaml
#   Dokumente  : pdf docx doc pages odt
#   Tabellen   : xlsx numbers csv
#   Präsent.   : pptx key
#   Design     : afpub (Textrahmen per Workaround)

set -uo pipefail

# ── Konfiguration ─────────────────────────────────────────────────────────────
ICLOUD_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
INDEX_DIR="$HOME/.icloud_index"
FT_INDEX="$INDEX_DIR/fulltext_index.json"
FT_LOG="$INDEX_DIR/fulltext_indexer.log"
LOCK_FILE="$INDEX_DIR/fulltext_indexer.lock"
EVICT_LIST="$INDEX_DIR/.evict_after_index"

BATCH_SIZE_MB="${BATCH_SIZE_MB:-200}"
BATCH_PAUSE_SEC="${BATCH_PAUSE_SEC:-5}"
MIN_TEXT_BYTES="${MIN_TEXT_BYTES:-50}"
MAX_TEXT_CHARS="${MAX_TEXT_CHARS:-50000}"

BATCH_SIZE_BYTES=$(( BATCH_SIZE_MB * 1024 * 1024 ))

# ── Hilfsfunktionen ───────────────────────────────────────────────────────────
mkdir -p "$INDEX_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$FT_LOG"
}

log_plain() {
  echo "$1" | tee -a "$FT_LOG"
}

# Lock: verhindert parallele Läufe
if [ -f "$LOCK_FILE" ]; then
  OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Volltext-Indexer läuft bereits (PID $OLD_PID). Abbruch." >&2
    exit 1
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

json_escape() {
  printf '%s' "$1" | python3 -c '
import json, sys
s = sys.stdin.read()
# Kürzen auf MAX_TEXT_CHARS
limit = '"$MAX_TEXT_CHARS"'
if len(s) > limit:
    s = s[:limit] + " …[gekürzt]"
print(json.dumps(s)[1:-1])
'
}

bytes_to_mb() {
  echo "scale=1; $1 / 1048576" | bc 2>/dev/null || echo "?"
}

# ── Werkzeuge prüfen ──────────────────────────────────────────────────────────
HAS_PDFTOTEXT=0; command -v pdftotext &>/dev/null && HAS_PDFTOTEXT=1
HAS_PANDOC=0;    command -v pandoc    &>/dev/null && HAS_PANDOC=1
HAS_PYTHON3=0;   command -v python3   &>/dev/null && HAS_PYTHON3=1
HAS_TEXTUTIL=0;  command -v textutil  &>/dev/null && HAS_TEXTUTIL=1  # macOS built-in

# Python-Bibliotheken prüfen
PYPDF_OK=0; DOCX_OK=0; OPENPYXL_OK=0; PPTX_OK=0
if [ "$HAS_PYTHON3" -eq 1 ]; then
  python3 -c "import pypdf"    &>/dev/null && PYPDF_OK=1
  python3 -c "import docx"     &>/dev/null && DOCX_OK=1
  python3 -c "import openpyxl" &>/dev/null && OPENPYXL_OK=1
  python3 -c "import pptx"     &>/dev/null && PPTX_OK=1
fi

# ── Text-Extraktion ───────────────────────────────────────────────────────────
extract_text() {
  local filepath="$1"
  local ext="${2,,}"   # Kleinbuchstaben
  local text=""

  case "$ext" in

    # Reine Textformate – direkt lesen
    txt|md|markdown|csv|rtf|sh|bash|zsh|py|rb|js|ts|jsx|tsx|\
    css|html|htm|xml|json|yaml|yml|toml|ini|conf|log|swift|m)
      text=$(head -c "$MAX_TEXT_CHARS" "$filepath" 2>/dev/null | strings -n 4 2>/dev/null || true)
      ;;

    # PDF
    pdf)
      if [ "$HAS_PDFTOTEXT" -eq 1 ]; then
        text=$(pdftotext -q -nopgbrk "$filepath" - 2>/dev/null | head -c "$MAX_TEXT_CHARS" || true)
      elif [ "$PYPDF_OK" -eq 1 ]; then
        text=$(python3 - "$filepath" <<'PYEOF' 2>/dev/null || true
import sys, pypdf
try:
    r = pypdf.PdfReader(sys.argv[1])
    parts = []
    for page in r.pages[:40]:
        t = page.extract_text() or ""
        parts.append(t)
        if sum(len(p) for p in parts) > 50000:
            break
    print(" ".join(parts))
except Exception:
    pass
PYEOF
)
      fi
      ;;

    # Word-Dokumente
    docx)
      if [ "$DOCX_OK" -eq 1 ]; then
        text=$(python3 - "$filepath" <<'PYEOF' 2>/dev/null || true
import sys, docx
try:
    d = docx.Document(sys.argv[1])
    print(" ".join(p.text for p in d.paragraphs if p.text.strip()))
except Exception:
    pass
PYEOF
)
      elif [ "$HAS_PANDOC" -eq 1 ]; then
        text=$(pandoc -f docx -t plain "$filepath" 2>/dev/null | head -c "$MAX_TEXT_CHARS" || true)
      fi
      ;;

    # Pages / DOC / ODT via pandoc oder textutil
    pages|doc|odt)
      if [ "$HAS_PANDOC" -eq 1 ]; then
        text=$(pandoc -t plain "$filepath" 2>/dev/null | head -c "$MAX_TEXT_CHARS" || true)
      elif [ "$HAS_TEXTUTIL" -eq 1 ]; then
        text=$(textutil -convert txt -stdout "$filepath" 2>/dev/null | head -c "$MAX_TEXT_CHARS" || true)
      fi
      ;;

    # Excel / Numbers
    xlsx|numbers)
      if [ "$OPENPYXL_OK" -eq 1 ] && [ "$ext" = "xlsx" ]; then
        text=$(python3 - "$filepath" <<'PYEOF' 2>/dev/null || true
import sys, openpyxl
try:
    wb = openpyxl.load_workbook(sys.argv[1], read_only=True, data_only=True)
    parts = []
    for ws in wb.worksheets:
        for row in ws.iter_rows(values_only=True):
            for cell in row:
                if cell is not None:
                    s = str(cell).strip()
                    if s:
                        parts.append(s)
            if sum(len(p) for p in parts) > 50000:
                break
        if sum(len(p) for p in parts) > 50000:
            break
    print(" ".join(parts))
except Exception:
    pass
PYEOF
)
      fi
      ;;

    # PowerPoint / Keynote
    pptx)
      if [ "$PPTX_OK" -eq 1 ]; then
        text=$(python3 - "$filepath" <<'PYEOF' 2>/dev/null || true
import sys
from pptx import Presentation
try:
    p = Presentation(sys.argv[1])
    parts = []
    for slide in p.slides:
        for shape in slide.shapes:
            if shape.has_text_frame:
                for para in shape.text_frame.paragraphs:
                    t = para.text.strip()
                    if t:
                        parts.append(t)
    print(" ".join(parts))
except Exception:
    pass
PYEOF
)
      elif [ "$HAS_PANDOC" -eq 1 ]; then
        text=$(pandoc -f pptx -t plain "$filepath" 2>/dev/null | head -c "$MAX_TEXT_CHARS" || true)
      fi
      ;;

    # Affinity Publisher – binäres Format, nur Notbehelf via strings
    afpub|afdesign|afphoto)
      text=$(strings -n 6 "$filepath" 2>/dev/null \
        | grep -v '^[[:space:]]*$' \
        | grep -E '.{6,}' \
        | head -c "$MAX_TEXT_CHARS" || true)
      ;;

    *)
      # Unbekannte Formate: strings versuchen, aber nur wenn <50 MB
      local size
      size=$(stat -f%z "$filepath" 2>/dev/null || echo 99999999)
      if (( size < 52428800 )); then
        text=$(strings -n 6 "$filepath" 2>/dev/null | head -c 2000 || true)
      fi
      ;;
  esac

  # Whitespace normalisieren
  text=$(echo "$text" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
  echo "$text"
}

# ── Hauptlogik ────────────────────────────────────────────────────────────────
log "=== iCloud Volltext-Indexer gestartet ==="
log "Batch-Limit: ${BATCH_SIZE_MB} MB | Min-Text: ${MIN_TEXT_BYTES} Bytes | Max-Text: ${MAX_TEXT_CHARS} Zeichen"

if [ ! -d "$ICLOUD_DIR" ]; then
  log "FEHLER: iCloud Drive nicht gefunden: $ICLOUD_DIR"
  exit 1
fi

# Unterstützte Erweiterungen (Hauptindex wird mitgelesen wenn vorhanden)
SUPPORTED_EXTS="txt md markdown csv rtf sh bash zsh py rb js ts jsx tsx css html htm xml json yaml yml toml ini conf swift m pdf docx doc pages odt xlsx numbers pptx key afpub afdesign afphoto"

# Dateien sammeln: lokale UND Cloud-Stubs mit unterstützten Erweiterungen
declare -a LOCAL_FILES=()
declare -a CLOUD_STUBS=()

is_supported_ext() {
  local ext="${1,,}"
  for e in $SUPPORTED_EXTS; do
    [ "$e" = "$ext" ] && return 0
  done
  return 1
}

log "Scanne iCloud Drive …"

while IFS= read -r -d '' filepath; do
  filename=$(basename "$filepath")
  ext="${filename##*.}"
  [ "$ext" = "$filename" ] && continue
  is_supported_ext "$ext" || continue
  LOCAL_FILES+=("$filepath")
done < <(find "$ICLOUD_DIR" \( -name ".*" ! -name "*.icloud" \) -prune -o -type f -print0 2>/dev/null)

while IFS= read -r -d '' stubpath; do
  stub_filename=$(basename "$stubpath")
  real_name="${stub_filename:1}"       # führenden Punkt entfernen
  real_name="${real_name%.icloud}"     # .icloud entfernen
  ext="${real_name##*.}"
  [ "$ext" = "$real_name" ] && continue
  is_supported_ext "$ext" || continue
  CLOUD_STUBS+=("$stubpath")
done < <(find "$ICLOUD_DIR" -name "*.icloud" -type f -print0 2>/dev/null)

log "Gefunden: ${#LOCAL_FILES[@]} lokale, ${#CLOUD_STUBS[@]} ausgelagerte Dateien mit unterstützten Formaten"

# ── Ausgabe-JSON vorbereiten ──────────────────────────────────────────────────
INDEXED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
TMP_JSON=$(mktemp /tmp/icloud_ft_XXXXXX.json)
echo '{"indexed_at":"'"$INDEXED_AT"'","entries":[' > "$TMP_JSON"

TOTAL_COUNT=0
TEXT_COUNT=0
SKIP_COUNT=0
FIRST_ENTRY=1

write_entry() {
  local real_path="$1"
  local is_cloud="$2"
  local text="$3"

  local filename; filename=$(basename "$real_path")
  local folder; folder=$(dirname "$real_path" | sed "s|$ICLOUD_DIR||" | sed 's|^/||')
  [ -z "$folder" ] && folder="/"
  local ext="${filename##*.}"
  [ "$ext" = "$filename" ] && ext=""

  local name_j; name_j=$(json_escape "$filename")
  local path_j; path_j=$(json_escape "$real_path")
  local folder_j; folder_j=$(json_escape "$folder")
  local ext_j; ext_j=$(json_escape "$ext")
  local text_j; text_j=$(json_escape "$text")

  if [ "$FIRST_ENTRY" -eq 1 ]; then
    FIRST_ENTRY=0
  else
    printf ',' >> "$TMP_JSON"
  fi

  printf '{"name":"%s","path":"%s","folder":"%s","extension":"%s","is_cloud_only":%s,"text":"%s"}' \
    "$name_j" "$path_j" "$folder_j" "$ext_j" "$is_cloud" "$text_j" >> "$TMP_JSON"
}

# ── Lokale Dateien direkt verarbeiten ─────────────────────────────────────────
log "── Phase 1: Lokale Dateien (${#LOCAL_FILES[@]}) ──"

for filepath in "${LOCAL_FILES[@]}"; do
  filename=$(basename "$filepath")
  ext="${filename##*.}"
  [ "$ext" = "$filename" ] && ext=""

  text=$(extract_text "$filepath" "$ext")
  TOTAL_COUNT=$((TOTAL_COUNT + 1))

  if [ ${#text} -lt "$MIN_TEXT_BYTES" ]; then
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  write_entry "$filepath" "0" "$text"
  TEXT_COUNT=$((TEXT_COUNT + 1))
  [ $((TEXT_COUNT % 100)) -eq 0 ] && log "  $TEXT_COUNT Einträge geschrieben …"
done

log "  Lokal: $TEXT_COUNT Einträge mit Text, $SKIP_COUNT übersprungen (zu wenig Text)"

# ── Ausgelagerte Dateien in Batches herunterladen ─────────────────────────────
if [ ${#CLOUD_STUBS[@]} -gt 0 ]; then
  log "── Phase 2: Ausgelagerte Dateien in Batches (${#CLOUD_STUBS[@]} Stubs) ──"

  > "$EVICT_LIST"   # Evict-Liste leeren

  BATCH_NUM=0
  BATCH_BYTES=0
  declare -a BATCH=()

  process_batch() {
    [ ${#BATCH[@]} -eq 0 ] && return
    BATCH_NUM=$((BATCH_NUM + 1))
    local batch_mb; batch_mb=$(bytes_to_mb "$BATCH_BYTES")
    log "  Batch $BATCH_NUM: ${#BATCH[@]} Dateien (~${batch_mb} MB) – starte Download …"

    # Alle Dateien im Batch gleichzeitig anfordern
    local downloaded=()
    for stub in "${BATCH[@]}"; do
      stub_filename=$(basename "$stub")
      real_name="${stub_filename:1}"
      real_name="${real_name%.icloud}"
      real_dir=$(dirname "$stub")
      real_path="$real_dir/$real_name"

      # brctl download löst den Download aus
      brctl download "$real_path" &>/dev/null || true
      downloaded+=("$real_path")
    done

    # Warten bis alle Dateien vorhanden sind (max. 120 Sekunden)
    local wait_total=0
    local all_ready=0
    while [ $wait_total -lt 120 ]; do
      all_ready=1
      for real_path in "${downloaded[@]}"; do
        [ -f "$real_path" ] || { all_ready=0; break; }
      done
      [ "$all_ready" -eq 1 ] && break
      sleep 2
      wait_total=$((wait_total + 2))
    done

    if [ "$all_ready" -eq 0 ]; then
      log "  WARNUNG: Batch $BATCH_NUM nicht vollständig heruntergeladen nach ${wait_total}s"
    fi

    # Text extrahieren
    local batch_text_count=0
    for real_path in "${downloaded[@]}"; do
      [ -f "$real_path" ] || continue
      filename=$(basename "$real_path")
      ext="${filename##*.}"
      [ "$ext" = "$filename" ] && ext=""

      text=$(extract_text "$real_path" "$ext")
      TOTAL_COUNT=$((TOTAL_COUNT + 1))

      if [ ${#text} -lt "$MIN_TEXT_BYTES" ]; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
      else
        write_entry "$real_path" "1" "$text"
        TEXT_COUNT=$((TEXT_COUNT + 1))
        batch_text_count=$((batch_text_count + 1))
      fi

      # Für spätere Rück-Auslagerung vormerken
      echo "$real_path" >> "$EVICT_LIST"
    done

    log "  Batch $BATCH_NUM fertig: $batch_text_count Einträge mit Text"

    # Batch zurücksetzen
    BATCH=()
    BATCH_BYTES=0
  }

  for stub in "${CLOUD_STUBS[@]}"; do
    stub_filename=$(basename "$stub")
    real_name="${stub_filename:1}"
    real_name="${real_name%.icloud}"

    # Dateigröße aus xattr schätzen (iCloud speichert sie im Stub)
    stub_size=$(xattr -p com.apple.cloud.itemSize "$stub" 2>/dev/null \
      | python3 -c "import sys; d=sys.stdin.read().strip(); print(int(d,16) if d.startswith('0x') or all(c in '0123456789abcdefABCDEF' for c in d) else int(d) if d.isdigit() else 0)" 2>/dev/null \
      || stat -f%z "$stub" 2>/dev/null || echo 0)

    # Batch würde Größenlimit überschreiten → erst verarbeiten
    if (( BATCH_BYTES + stub_size > BATCH_SIZE_BYTES && ${#BATCH[@]} > 0 )); then
      process_batch
      log "  Pause ${BATCH_PAUSE_SEC}s vor nächstem Batch …"
      sleep "$BATCH_PAUSE_SEC"
    fi

    BATCH+=("$stub")
    BATCH_BYTES=$((BATCH_BYTES + stub_size))
  done

  # Letzten Batch verarbeiten
  process_batch

  # ── Dateien zurück in die Cloud auslagern ─────────────────────────────────
  if [ -s "$EVICT_LIST" ]; then
    log "── Phase 3: Rück-Auslagerung in iCloud …"
    local evict_count=0
    while IFS= read -r real_path; do
      [ -f "$real_path" ] || continue
      brctl evict "$real_path" &>/dev/null || true
      evict_count=$((evict_count + 1))
    done < "$EVICT_LIST"
    rm -f "$EVICT_LIST"
    log "  $evict_count Dateien zurück ausgelagert"
  fi
fi

# ── Index abschließen ─────────────────────────────────────────────────────────
echo ']}' >> "$TMP_JSON"

# JSON validieren
if python3 -c "import json,sys; json.load(open('$TMP_JSON'))" &>/dev/null; then
  mv "$TMP_JSON" "$FT_INDEX"
  INDEX_SIZE=$(du -sh "$FT_INDEX" | cut -f1)
  log "── Fertig ──"
  log "Gesamt: $TOTAL_COUNT Dateien geprüft"
  log "Index:  $TEXT_COUNT Einträge mit Volltext"
  log "Übersp: $SKIP_COUNT (kein auswertbarer Text)"
  log "Datei:  $FT_INDEX ($INDEX_SIZE)"
else
  log "FEHLER: Erzeugte JSON-Datei ist ungültig. Index nicht überschrieben."
  log "  Temporäre Datei: $TMP_JSON"
  exit 1
fi
