#!/bin/sh
# Mirror Project Gutenberg *-images-3.epub files into $RAW, downloading each
# filename once. Files land in $STAGE, get recorded in SQLite, and only then
# move into $RAW, so the consumer can take them at any time without
# triggering re-downloads.
set -eu

SRC="${SRC:-aleph.gutenberg.org::gutenberg-epub/}"
DB="${DB:-/db/sync_state.db}"
RAW="${RAW:-/gutenberg/raw}"
STAGE="${STAGE:-/gutenberg/staging}"   # must be on the same mount as RAW
BWLIMIT="${BWLIMIT:-500}"
SYNC_INTERVAL="${SYNC_INTERVAL:-86400}"
RETRY_INTERVAL="${RETRY_INTERVAL:-300}"
TMP=/tmp/gutenberg-sync

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }
db()  { sqlite3 -bail -cmd '.timeout 10000' "$DB" "$@"; }

# Long-running commands run in the background and are waited on, so SIGTERM
# is handled immediately instead of after the command finishes.
CHILD=""
run() {
  "$@" &
  CHILD=$!
  run_rc=0
  wait "$CHILD" || run_rc=$?
  CHILD=""
  return "$run_rc"
}

cleanup() {
  log "Caught signal, shutting down..."
  if [ -n "$CHILD" ]; then
    kill "$CHILD" 2>/dev/null || true
    wait "$CHILD" 2>/dev/null || true   # let rsync delete its temp file
  fi
  exit 0
}
trap cleanup TERM INT

# Never add --partial: a killed transfer would leave a truncated file under
# its real name, which would then be recorded and handed off.
rs() { run rsync --no-motd --timeout=600 --contimeout=60 --bwlimit="$BWLIMIT" "$@"; }

retry_later() {
  log "ERROR: $*; retrying in ${RETRY_INTERVAL}s"
  run sleep "$RETRY_INTERVAL"
}

# Insert the basenames of the paths listed in $1 (one per line).
record() {
  [ -s "$1" ] || return 0
  sed 's|.*/||' "$1" > "$TMP/names.lst"
  db <<EOF
CREATE TEMP TABLE _import (filename TEXT);
.import $TMP/names.lst _import
INSERT OR IGNORE INTO synced_books (filename) SELECT filename FROM _import;
EOF
}

# Record whatever fully landed in STAGE, then move it into RAW. rsync only
# renames a file into place once it's complete (temp files are dot-prefixed),
# so every match is a whole file.
flush_stage() {
  find "$STAGE" -type f -name '.*' -delete   # temp files from a SIGKILLed rsync
  find "$STAGE" -type f -name '*-images-3.epub' > "$TMP/landed.lst"
  [ -s "$TMP/landed.lst" ] || return 0
  record "$TMP/landed.lst"
  while IFS= read -r f; do mv -f "$f" "$RAW/"; done < "$TMP/landed.lst"
  log "Recorded and handed off $(wc -l < "$TMP/landed.lst") files"
}

mkdir -p "$TMP" "$STAGE" "$RAW"
mount_of() { df -P "$1" | awk 'NR == 2 { print $NF }'; }
[ "$(mount_of "$STAGE")" = "$(mount_of "$RAW")" ] || {
  log "FATAL: STAGE ($STAGE) and RAW ($RAW) must be on the same mount"; exit 1; }

db "CREATE TABLE IF NOT EXISTS synced_books (
  filename TEXT PRIMARY KEY,
  synced_at TEXT DEFAULT (datetime('now'))
);"

# Files already in RAW count as synced (e.g. left there by the old version);
# files left in STAGE by an interrupted run get recorded and handed off.
find "$RAW" -type f -name '*-images-3.epub' > "$TMP/raw.lst"
record "$TMP/raw.lst"
flush_stage

while :; do
  log "===== Starting sync cycle ====="

  # --- List matching files on the mirror ---
  # Diffing against the DB locally avoids sending one exclude rule per synced
  # book, which PG's server would test against every file in the module.
  rc=0
  rs --list-only -r --include='*/' --include='*-images-3.epub' --exclude='*' \
    "$SRC" > "$TMP/remote.raw" || rc=$?
  case $rc in
    0) ;;
    23|24) log "WARN: listing incomplete (rsync exit $rc)" ;;
    *) retry_later "listing failed (rsync exit $rc)"; continue ;;
  esac
  awk '/^-/ { print $NF }' "$TMP/remote.raw" > "$TMP/remote.lst"
  [ -s "$TMP/remote.lst" ] || log "WARN: no matching files on mirror - layout changed?"

  # --- Keep paths whose basename isn't in the DB ---
  db 'SELECT filename FROM synced_books;' > "$TMP/synced.lst"
  awk -F/ 'FILENAME == ARGV[1] { seen[$0] = 1; next } !($NF in seen)' \
    "$TMP/synced.lst" "$TMP/remote.lst" > "$TMP/new.lst"
  log "Mirror: $(wc -l < "$TMP/remote.lst") matching, $(wc -l < "$TMP/new.lst") new"

  # --- Fetch into STAGE; record + hand off whatever landed, even on failure ---
  if [ -s "$TMP/new.lst" ]; then
    rc=0
    rs -tv --no-relative --files-from="$TMP/new.lst" "$SRC" "$STAGE/" || rc=$?
    flush_stage
    case $rc in
      0) ;;
      23|24) log "WARN: partial transfer (rsync exit $rc); the rest retries next cycle" ;;
      *) retry_later "fetch failed (rsync exit $rc)"; continue ;;
    esac
  fi

  # Directories emptied by the consumer; -mindepth 1 keeps RAW itself
  find "$RAW" -mindepth 1 -type d -empty -delete 2>/dev/null || true

  log "Total tracked books: $(db 'SELECT COUNT(*) FROM synced_books;')"
  log "Done. Sleeping ${SYNC_INTERVAL}s..."
  run sleep "$SYNC_INTERVAL"
done
