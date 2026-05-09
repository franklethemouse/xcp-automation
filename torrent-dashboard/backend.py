#!/usr/bin/env python3
"""
backend.py — Torrent Dashboard Backend
Runs on http://0.0.0.0:5000

Routes:
  GET  /                    – serve dashboard HTML
  GET  /status              – health check
  POST /deluge              – proxy Deluge JSON-RPC calls
  GET  /ipt-proxy           – fetch IPTorrents pages via Playwright (Cloudflare bypass)
  GET  /movies-search       – search IPTorrents movies page, return card data
  POST /fetch-torrent       – download .torrent file via Playwright, return base64
  POST /process             – run movie_processor.sh on a path

Dependencies:
    pip install flask flask-cors requests beautifulsoup4 lxml playwright --break-system-packages
    playwright install chromium
    playwright install-deps chromium
"""

import base64
import os
import re
import subprocess
import sys
import tempfile

import requests
from bs4 import BeautifulSoup
from flask import Flask, jsonify, request
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

IPT_BASE = "https://www.iptorrents.com"
SESSION_FILE = "/usr/local/bin/ipt_session.json"


# ── Helpers ───────────────────────────────────────────────────────────────────

def load_ipt_cookies():
    """Load IPTorrents session cookies and ensure domain format is correct."""
    import json
    with open(SESSION_FILE) as f:
        cookies = json.load(f)
    for ck in cookies:
        if not ck["domain"].startswith("."):
            ck["domain"] = "." + ck["domain"]
    return cookies


def save_ipt_cookies(cookies):
    """Save updated cookies back to session file (only if non-empty)."""
    import json
    if cookies:
        with open(SESSION_FILE, "w") as f:
            json.dump(cookies, f, indent=2)


def run_playwright_search(url):
    """
    Fetch an IPTorrents URL using Playwright (bypasses Cloudflare).
    Returns HTML string. Fetches up to 4 pages and merges the torrent tables.
    """
    import json
    from playwright.sync_api import sync_playwright

    cookies = load_ipt_cookies()

    pages_html = []
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, args=["--no-sandbox"])
        ctx = browser.new_context(
            user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        )
        ctx.add_cookies(cookies)
        page = ctx.new_page()

        for pg in range(4):
            paged_url = url + (f"&p={pg+1}" if pg > 0 else "")
            page.goto(paged_url, wait_until="networkidle", timeout=30000)
            if "login" in page.url:
                browser.close()
                raise Exception("IPT_LOGIN")
            try:
                page.wait_for_selector("table#torrents", timeout=8000)
            except Exception:
                break
            pages_html.append(page.content())
            has_next = page.query_selector("a:has-text('Next')")
            if not has_next:
                break

        updated = ctx.cookies()
        save_ipt_cookies(updated)
        browser.close()

    if not pages_html:
        return ""

    # Merge all pages into first page's table
    base_soup = BeautifulSoup(pages_html[0], "lxml")
    base_table = base_soup.find("table", id="torrents")
    if base_table and len(pages_html) > 1:
        for extra_html in pages_html[1:]:
            extra_soup = BeautifulSoup(extra_html, "lxml")
            extra_table = extra_soup.find("table", id="torrents")
            if extra_table:
                for row in extra_table.find_all("tr")[1:]:
                    base_table.append(row)

    return str(base_soup)


def parse_ipt_results(html):
    """
    Parse IPTorrents search results table.
    Column layout: 0:category  1:name  2:bookmark  3:download  4:comments  5:size  6:seeders  7:leechers
    """
    soup = BeautifulSoup(html, "lxml")
    rows = []
    table = soup.find("table", id="torrents")
    if not table:
        return rows

    for tr in table.find_all("tr"):
        cells = tr.find_all("td")
        if len(cells) < 8:
            continue
        try:
            cat_img  = cells[0].find("img")
            category = cat_img.get("alt", "") if cat_img else ""

            name_link = cells[1].find("a", class_="b") or cells[1].find("a")
            if not name_link:
                continue
            # Remove tooltip divs before extracting name
            for tip in name_link.find_all("div"):
                tip.decompose()
            name     = name_link.get_text(strip=True)
            info_url = IPT_BASE + name_link.get("href", "")

            dl_link = cells[3].find("a")
            dl_url  = (IPT_BASE + dl_link.get("href", "")) if dl_link else ""

            size     = cells[5].get_text(strip=True)
            seeders  = int(re.sub("[^0-9]", "", cells[6].get_text(strip=True)) or 0)
            leechers = int(re.sub("[^0-9]", "", cells[7].get_text(strip=True)) or 0)
            year_m   = re.search(r"(19|20)[0-9]{2}", name)

            rows.append({
                "name":         name,
                "info_url":     info_url,
                "download_url": dl_url,
                "size":         size,
                "seeders":      seeders,
                "leechers":     leechers,
                "year":         year_m.group(0) if year_m else "",
                "category":     category,
            })
        except Exception:
            continue

    return rows


# ── Routes ────────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    """Serve the dashboard HTML."""
    html_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "torrent_dashboard.html")
    if os.path.exists(html_path):
        with open(html_path) as f:
            return f.read(), 200, {"Content-Type": "text/html"}
    return "Dashboard not found — place torrent_dashboard.html next to backend.py", 404


@app.route("/status")
def status():
    return jsonify({"ok": True, "service": "torrent-dashboard-backend"})


@app.route("/deluge", methods=["POST"])
def deluge_proxy():
    """Proxy Deluge JSON-RPC calls to avoid CORS issues."""
    data        = request.get_json(force=True)
    deluge_url  = data.get("url", "http://localhost:8112/json")
    payload     = data.get("payload", {})
    session_id  = data.get("session_id", "")

    headers = {"Content-Type": "application/json"}
    if session_id:
        headers["Cookie"] = f"_session_id={session_id}"

    try:
        r = requests.post(deluge_url, json=payload, headers=headers, timeout=10)
        resp = jsonify(r.json())
        if "Set-Cookie" in r.headers:
            resp.headers["X-Session-Cookie"] = r.headers["Set-Cookie"]
        return resp
    except Exception as e:
        return jsonify({"error": str(e)}), 502


@app.route("/ipt-proxy")
def ipt_proxy():
    """
    Fetch an IPTorrents search/browse page via Playwright.
    Merges up to 4 pages of results into a single HTML response.
    """
    url = request.args.get("url", "").strip()
    if not url or not url.startswith(IPT_BASE):
        return jsonify({"error": "Invalid URL"}), 400

    try:
        html = run_playwright_search(url)
        if not html:
            return "No results", 200, {"Content-Type": "text/html"}
        return html, 200, {"Content-Type": "text/html; charset=utf-8"}
    except Exception as e:
        if "IPT_LOGIN" in str(e):
            return jsonify({"error": "IPT_LOGIN"}), 401
        return jsonify({"error": str(e)}), 502


@app.route("/movies-search")
def movies_search():
    """
    Search IPTorrents movies page and return rich movie card data
    (title, year, rating, poster, genres, torrent_url).
    """
    import json as _json
    from playwright.sync_api import sync_playwright

    q = request.args.get("q", "").strip()
    if not q:
        return jsonify({"error": "Missing query"}), 400

    try:
        cookies = load_ipt_cookies()
    except Exception as e:
        return jsonify({"error": f"No session: {e}"}), 500

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True, args=["--no-sandbox"])
            ctx = browser.new_context(
                user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
            )
            ctx.add_cookies(cookies)
            page = ctx.new_page()
            page.goto(f"{IPT_BASE}/movies?q={q}&r0=&r1=&y0=&y1=", wait_until="networkidle", timeout=30000)
            page.wait_for_timeout(2000)
            html = page.content()
            save_ipt_cookies(ctx.cookies())
            browser.close()

        soup = BeautifulSoup(html, "lxml")
        cards = soup.find_all("table", class_="t0")
        results = []

        for card in cards:
            try:
                title_tag = card.find("b", class_="MovieTitle")
                if not title_tag:
                    continue
                title_a = title_tag.find("a")
                if not title_a:
                    continue

                title       = title_a.get_text(strip=True)
                year_m      = re.search(r"(19|20)\d{2}", title_tag.get_text())
                year        = year_m.group(0) if year_m else ""
                torrent_href= title_a.get("href", "")
                torrent_url = IPT_BASE + torrent_href if torrent_href.startswith("/") else torrent_href

                img    = card.find("img")
                poster = img.get("src", "") if img else ""

                rating = ""
                for span in card.find_all("span"):
                    t = span.get_text(strip=True)
                    if t.startswith("Rating:"):
                        rating = t.replace("Rating:", "").strip()
                        break

                genres = []
                for a in card.find_all("a"):
                    href = a.get("href", "")
                    if href.startswith("?q="):
                        txt = a.get_text(strip=True)
                        if txt and not any(c.isdigit() for c in txt) and len(txt) < 25:
                            genres.append(txt)

                results.append({
                    "title":       title,
                    "year":        year,
                    "rating":      rating,
                    "poster":      poster,
                    "torrent_url": torrent_url,
                    "genres":      genres[:4],
                })
            except Exception:
                continue

        return jsonify(results)

    except Exception as e:
        return jsonify({"error": str(e)}), 502


@app.route("/search")
def search():
    """Legacy search endpoint (flat torrent list, not movie cards)."""
    q      = request.args.get("q", "").strip()
    cat    = request.args.get("cat", "")
    sort   = request.args.get("sort", "seeders")

    if not q:
        return jsonify({"error": "Missing query 'q'"}), 400

    url = f"{IPT_BASE}/t?q={q}&qf=all&o={sort}"
    try:
        html    = run_playwright_search(url)
        results = parse_ipt_results(html)
        return jsonify(results)
    except Exception as e:
        if "IPT_LOGIN" in str(e):
            return jsonify({"error": "IPT_LOGIN"}), 401
        return jsonify({"error": str(e)}), 502


@app.route("/fetch-torrent", methods=["POST"])
def fetch_torrent():
    """
    Download a .torrent file from IPTorrents using Playwright (Cloudflare bypass).
    Returns base64-encoded torrent data and filename.
    """
    data = request.get_json(force=True)
    url  = data.get("url", "").strip()
    if not url:
        return jsonify({"error": "Missing url"}), 400

    # Playwright must run in a subprocess to avoid Flask's event loop conflict
    script = """
import sys, json
from playwright.sync_api import sync_playwright

url          = sys.argv[1]
session_file = sys.argv[2]
out_file     = sys.argv[3]

with open(session_file) as f:
    cookies = json.load(f)
for ck in cookies:
    if not ck["domain"].startswith("."):
        ck["domain"] = "." + ck["domain"]

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, args=["--no-sandbox"])
    ctx = browser.new_context(
        user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        accept_downloads=True
    )
    ctx.add_cookies(cookies)
    page = ctx.new_page()
    with page.expect_download(timeout=30000) as dl_info:
        page.evaluate(
            "(u) => { const a=document.createElement('a'); a.href=u; a.download='t.torrent'; document.body.appendChild(a); a.click(); }",
            url
        )
    download = dl_info.value
    fname = download.suggested_filename or "download.torrent"
    download.save_as(out_file)
    browser.close()
    print(fname)
"""

    tmp = tempfile.NamedTemporaryFile(suffix=".torrent", delete=False)
    tmp.close()
    try:
        result = subprocess.run(
            [sys.executable, "-c", script, url, SESSION_FILE, tmp.name],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            return jsonify({"error": result.stderr.strip() or "Download failed"}), 502
        filename = result.stdout.strip() or "download.torrent"
        with open(tmp.name, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        return jsonify({"b64": b64, "filename": filename})
    except subprocess.TimeoutExpired:
        return jsonify({"error": "Download timed out"}), 504
    except Exception as e:
        return jsonify({"error": str(e)}), 502
    finally:
        try:
            os.unlink(tmp.name)
        except Exception:
            pass


@app.route("/process", methods=["POST"])
def process():
    """
    Run movie_processor.sh against a completed torrent's path.
    Expects: { "path": "/content/TORRENT/Movie.Name", "script": "/usr/bin/move_and_link_movies.sh" }
    """
    data   = request.get_json(force=True)
    path   = data.get("path", "").strip()
    script = data.get("script", "/usr/bin/move_and_link_movies.sh").strip()

    if not path:
        return jsonify({"ok": False, "error": "Missing 'path'"}), 400
    if not os.path.exists(script):
        return jsonify({"ok": False, "error": f"Script not found: {script}"}), 400
    if not os.path.exists(path):
        return jsonify({"ok": False, "error": f"Path not found: {path}"}), 400

    try:
        result = subprocess.run(
            ["bash", script, path],
            capture_output=True, text=True, timeout=300
        )
        lines = (result.stdout + result.stderr).splitlines()
        # Script exits 1 even on success (bash exit code) — check log content
        success = result.returncode == 0 or any("Processed: 1" in l for l in lines)
        if success:
            return jsonify({"ok": True, "lines": lines})
        else:
            return jsonify({"ok": False, "error": f"Script exited {result.returncode}", "lines": lines})
    except subprocess.TimeoutExpired:
        return jsonify({"ok": False, "error": "Processing timed out (>5 min)"}), 504
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"[backend] Starting on http://0.0.0.0:{port}")
    app.run(host="0.0.0.0", port=port, debug=False)
