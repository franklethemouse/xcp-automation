# Torrent Dashboard

A self-hosted web dashboard for searching IPTorrents, managing Deluge downloads, and auto-processing movies via TMDb.

## Stack

- **backend.py** — Flask API server (Python 3)
- **torrent_dashboard.html** — Single-file web frontend
- **movie_processor.sh** — Bash script to rename, move, and set permissions on completed downloads

## Features

- Search IPTorrents via movie cards (poster, rating, cast, genres)
- Click a movie to see all available torrents (sortable by name, size, seeds)
- Add torrents to Deluge with one click
- Monitor active transfers with sortable/resizable columns, pagination, ETA
- Process completed downloads: renames via TMDb API, moves to `/content/MOVIES`
- RAR extraction support (unrar)
- Cloudflare bypass via Playwright headless Chromium

## Requirements

```bash
pip install flask flask-cors requests beautifulsoup4 lxml playwright --break-system-packages
playwright install chromium
playwright install-deps chromium
apt install unrar
```

## Setup

1. Copy `backend.py` and `torrent_dashboard.html` to `/usr/local/bin/`
2. Copy `movie_processor.sh` to `/usr/bin/move_and_link_movies.sh` and `chmod +x`
3. Log into IPTorrents once via Playwright to create the session file:

```bash
# Edit and run this to save your IPT session
python3 -c "
import json
cookies = [
    {'name': 'uid', 'value': 'YOUR_UID', 'domain': '.iptorrents.com', 'path': '/'},
    {'name': 'pass', 'value': 'YOUR_PASS', 'domain': '.iptorrents.com', 'path': '/'}
]
json.dump(cookies, open('/usr/local/bin/ipt_session.json', 'w'))
"
```

4. Install and start the systemd service:

```bash
cat > /etc/systemd/system/torrent-backend.service << 'SERVICE'
[Unit]
Description=Torrent Dashboard Backend
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/backend.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now torrent-backend
```

5. Open `http://YOUR_SERVER_IP:5000` in your browser
6. Click ⚙ Config and set your Deluge URL, password, and IPTorrents cookie

## Configuration (in dashboard Config panel)

| Setting | Default | Description |
|---|---|---|
| Deluge URL | `http://192.168.1.84:8112/json` | Deluge Web UI JSON-RPC endpoint |
| Deluge password | — | Your Deluge Web UI password |
| IPTorrents cookie | — | `uid=X; pass=Y` from browser cookies |
| Movie destination | `/content/MOVIES` | Where processed movies are moved |
| Processor script | `/usr/bin/move_and_link_movies.sh` | Path to movie_processor.sh |
| Backend API URL | `http://192.168.1.84:5000` | URL of this backend |

## Movie Processor

The `movie_processor.sh` script:
- Accepts a path (torrent directory or file)
- Extracts `.rar` / `.r00` archives if present
- Looks up the movie title via TMDb API
- Renames to `Movie Title (Year).ext`
- Moves to destination directory
- Sets permissions (644) and ownership (root:root)

Requires a TMDb API token — set `API_TOKEN` in the script.
