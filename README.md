# iCloud Search

A fast, local search tool for all your iCloud Drive files — including files that are stored in the cloud and not currently downloaded to your Mac.

Apple's built-in Spotlight search often misses cloud-only files. This tool solves that by building a local index of all your iCloud Drive files (metadata and full text) and making them searchable through a clean browser interface.

![iCloud Search Screenshot](screenshot.png)

---

## Features

- **Finds cloud-only files** — even files not currently on your Mac
- **Full-text search** — searches inside PDFs, Word docs, text files, and more
- **Always available** — runs as a local web server, accessible at any time
- **Nightly updates** — index refreshes automatically at 02:00
- **macOS native look** — Finder-style interface in the browser
- **No internet connection required** — everything runs locally

## Supported file formats

| Category | Formats |
|----------|---------|
| Text / Code | txt, md, rtf, sh, py, js, ts, css, html, xml, json, yaml |
| Documents | pdf, docx, doc, pages, odt |
| Spreadsheets | xlsx, numbers, csv |
| Presentations | pptx, key |
| Design | afpub (text frames) |

---

## Requirements

- macOS 12 or later
- Python 3 (comes with macOS, or install via [Homebrew](https://brew.sh): `brew install python3`)
- iCloud Drive enabled

---

## Installation

```bash
git clone https://github.com/janrueter/icloud-search.git
cd icloud-search
chmod +x install.sh
./install.sh
```

The installer will:
1. Copy scripts to `~/Library/Scripts/icloud-search/`
2. Set up a nightly metadata indexer (runs at 02:00)
3. Start a local web server on port 8742 (always on, restarts automatically)
4. Run the first metadata index immediately

Then open your browser at:

```
http://127.0.0.1:8742/icloud_search.html
```

### Full-text index (optional but recommended)

After installation, run once to build the full-text index:

```bash
bash ~/Library/Scripts/icloud-search/icloud_fulltext_indexer.sh
```

This may take a while on first run depending on how many files you have. Cloud-only files are temporarily downloaded, indexed, and evicted again automatically.

---

## How it works

```
iCloud Drive
     │
     ▼
icloud_indexer.sh          – scans all files (local + cloud stubs)
     │                       runs nightly via LaunchAgent
     ▼
~/.icloud_index/
  index.json               – metadata for all files
  fulltext_index.json      – extracted text content
  icloud_search.html       – search UI
     │
     ▼
icloud_server.py           – local HTTP server (port 8742)
     │                       always running via LaunchAgent
     ▼
Browser → http://127.0.0.1:8742/icloud_search.html
```

---

## Configuration

The full-text indexer can be tuned via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `BATCH_SIZE_MB` | 200 | Max download volume per batch (MB) |
| `BATCH_PAUSE_SEC` | 5 | Pause between batches (seconds) |
| `MIN_TEXT_BYTES` | 50 | Minimum text length to index |
| `MAX_TEXT_CHARS` | 50000 | Max characters stored per file |

Example:
```bash
BATCH_SIZE_MB=500 bash ~/Library/Scripts/icloud-search/icloud_fulltext_indexer.sh
```

---

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.icloud-search.indexer.plist
launchctl unload ~/Library/LaunchAgents/com.icloud-search.server.plist
rm ~/Library/LaunchAgents/com.icloud-search.indexer.plist
rm ~/Library/LaunchAgents/com.icloud-search.server.plist
rm -rf ~/Library/Scripts/icloud-search
rm -rf ~/.icloud_index
```

---

## License

MIT License – use freely, modify as you like.
