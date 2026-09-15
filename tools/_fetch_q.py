import io, os, re, sys, subprocess, urllib.request

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

PAGES = {
    "base_characters": "https://quaternius.com/packs/universalbasecharacters.html",
    "ual": "https://quaternius.com/packs/universalanimationlibrary.html",
    "ual2": "https://quaternius.com/packs/universalanimationlibrary2.html",
    "steampunk": "https://quaternius.com/packs/turretpack.html",
    "outfits": "https://quaternius.com/packs/modularcharacteroutfitsfantasy.html",
}

out_dir = r"D:\SteamPunkExtraction\_q_pages"
os.makedirs(out_dir, exist_ok=True)

for name, url in PAGES.items():
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        html = urllib.request.urlopen(req, timeout=60).read().decode("utf-8", "replace")
    except Exception as e:
        print("== %-18s FETCH FAIL %s" % (name, e))
        continue
    io.open(os.path.join(out_dir, name + ".html"), "w", encoding="utf-8", newline="").write(html)
    links = set(re.findall(r'href=["\']([^"\']+)["\']', html))
    hits = [l for l in sorted(links)
            if any(k in l.lower() for k in (".zip", "download", "drive.google", ".rar", "gumroad", "/files/"))]
    print("== %-18s %d bytes, %d candidate links" % (name, len(html), len(hits)))
    for l in hits[:14]:
        print("     ", l)
