#!/bin/sh
set -eu

DB="/db/sync_state.db"
RAW="/gutenberg/raw"
SYNC_INTERVAL=86400

# --- Graceful shutdown on SIGTERM/SIGINT (docker stop) ---
SLEEP_PID=""
cleanup() {
  echo "[$(date -Iseconds)] Caught signal, shutting down..."
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  exit 0
}
trap cleanup TERM INT

# --- Initialise DB ---
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS synced_books (
  filename TEXT PRIMARY KEY,
  synced_at TEXT DEFAULT (datetime('now'))
);"

while true; do
  echo "============================================"
  echo "[$(date -Iseconds)] Starting sync cycle"
  echo "============================================"

  # --- Build exclude list from DB ---
  echo "[$(date -Iseconds)] Building exclude list..."
  sqlite3 "$DB" "SELECT filename FROM synced_books;" > /tmp/exclude.txt
  EXCLUDED=$(wc -l < /tmp/exclude.txt)
  echo "[$(date -Iseconds)] Excluding ${EXCLUDED} previously synced files"

  # --- Rsync ---
  # Filter order: include dirs (for traversal) -> exclude already-synced
  # -> include target epub pattern -> exclude everything else
  echo "[$(date -Iseconds)] Starting rsync..."
  if rsync -avm --bwlimit=500 \
      --include='*/' \
      --exclude-from=/tmp/exclude.txt \
      --include='*-images-3.epub' \
      --exclude='*' \
      aleph.gutenberg.org::gutenberg-epub "$RAW/"; then
    echo "[$(date -Iseconds)] Rsync completed successfully"
  else
    RC=$?
    # rsync exit 24 = "partial transfer due to vanished source files" (harmless)
    if [ "$RC" -eq 24 ]; then
      echo "[$(date -Iseconds)] Rsync completed with vanished-file warnings (exit 24, harmless)"
    else
      echo "[$(date -Iseconds)] ERROR: rsync failed with exit code $RC, skipping DB update"
      sleep 300
      continue
    fi
  fi

  # --- Batch-insert new files into SQLite ---
  echo "[$(date -Iseconds)] Scanning for new files..."
  find "$RAW" -type f -name '*.epub' | sed 's|.*/||' | sort > /tmp/current_files.txt

  # Diff against what's already in DB to get only genuinely new files
  sqlite3 "$DB" "SELECT filename FROM synced_books;" | sort > /tmp/db_files.txt
  NEW_FILES=$(comm -23 /tmp/current_files.txt /tmp/db_files.txt)

  NEW_COUNT=$(echo "$NEW_FILES" | grep -c '.' || true)
  if [ "$NEW_COUNT" -gt 0 ]; then
    echo "[$(date -Iseconds)] Inserting ${NEW_COUNT} new files into DB..."
    # Write as tab-separated values and bulk-import (avoids SQL injection entirely)
    echo "$NEW_FILES" > /tmp/new_files.txt
    sqlite3 "$DB" <<EOF
.mode csv
.separator "\n"
CREATE TEMP TABLE _import (filename TEXT);
.import /tmp/new_files.txt _import
INSERT OR IGNORE INTO synced_books (filename)
  SELECT filename FROM _import;
DROP TABLE _import;
EOF
    echo "[$(date -Iseconds)] DB updated"
  else
    echo "[$(date -Iseconds)] No new files to record"
  fi

  # --- Cleanup empty directories rsync leaves behind ---
  find "$RAW" -type d -empty -delete 2>/dev/null || true

  TOTAL=$(sqlite3 "$DB" "SELECT COUNT(*) FROM synced_books;")
  echo "[$(date -Iseconds)] Total tracked books: ${TOTAL}"
  echo "[$(date -Iseconds)] Done. Sleeping ${SYNC_INTERVAL}s..."

  # Sleep in background so trap can interrupt it
  sleep "$SYNC_INTERVAL" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=""
done
