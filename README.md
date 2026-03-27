# gutenberg-sync

Automatically mirrors Project Gutenberg's EPUB catalog via rsync and tracks sync state in a local SQLite database. Designed to run as a Docker container on a home server.

## What it does

- Syncs `*-images-3.epub` files from `aleph.gutenberg.org::gutenberg-epub` (the illustrated EPUB variant)
- Tracks already-synced filenames in SQLite so subsequent runs skip them entirely
- Runs on a 24-hour cycle by default
- Handles rsync failures gracefully and shuts down cleanly on `docker stop`

## Setup

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_USERNAME/gutenberg-sync.git
```

Edit `docker-compose.yml` to set your volume paths:

- `/path/to/ebooks/gutenberg` — where the downloaded EPUBs will be stored
- `/path/to/gutenberg-sync/db` — where the SQLite database will live

### 2. Set directory ownership

The container runs as UID/GID `1003:1003` by default. Match this on the host:

```bash
sudo mkdir -p /path/to/ebooks/gutenberg/raw
sudo mkdir -p /path/to/gutenberg-sync/db
sudo chown 1003:1003 /path/to/ebooks/gutenberg/raw
sudo chown 1003:1003 /path/to/gutenberg-sync/db
```

Change the `user:` field in `docker-compose.yml` if you need a different UID/GID.

### 3. Build and start

```bash
docker compose build gutenberg-sync
docker compose up -d gutenberg-sync
```

### 4. Verify

```bash
docker logs -f gutenberg-sync
```

The first sync will take a while — rsync needs to scan the full Gutenberg mirror before files start downloading.

## Useful commands

```bash
# Total books synced
docker exec gutenberg-sync sqlite3 /db/sync_state.db "SELECT COUNT(*) FROM synced_books;"

# Most recently synced books
docker exec gutenberg-sync sqlite3 /db/sync_state.db \
  "SELECT filename, synced_at FROM synced_books ORDER BY synced_at DESC LIMIT 10;"

# Trigger an immediate sync
docker restart gutenberg-sync
```

## Configuration

| Setting | Location | Default |
|---|---|---|
| Sync interval | `SYNC_INTERVAL` in `sync.sh` | `86400` (24h) |
| Bandwidth limit | `--bwlimit` in `sync.sh` | `500` KB/s |
| EPUB variant | `--include` pattern in `sync.sh` | `*-images-3.epub` |
| Container UID/GID | `user:` in `docker-compose.yml` | `1003:1003` |

## File structure

```
gutenberg-sync/
├── docker-compose.yml
├── Dockerfile
├── sync.sh
└── README.md
```

## License

Do whatever you want with it.
