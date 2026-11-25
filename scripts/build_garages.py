"""Build data/garages.json: all car repair and tyre shops in the Netherlands from OpenStreetMap,
marked "APK-erkend" when the RDW lists the business as accredited for APK on light vehicles.

The site searches this file in the browser, so a garage search never depends on a live
(and often overloaded) Overpass server and no visitor location leaves the browser.

Run it again now and then to refresh the data (a GitHub Action does this every month):
    python scripts/build_garages.py              # downloads from Overpass (can take minutes)
    python scripts/build_garages.py export.json  # uses an Overpass JSON export you already have

Data: (c) OpenStreetMap contributors, available under the Open Database License (ODbL).
APK accreditations: RDW Open Data (Erkende Bedrijven, Erkenningen), CC0.
"""
import json
import re
import sys
import urllib.parse
import urllib.request
from datetime import date
from pathlib import Path

OVERPASS = "https://overpass-api.de/api/interpreter"
QUERY = """[out:json][timeout:600];
area["ISO3166-1"="NL"][admin_level=2]->.nl;
(nwr[shop=car_repair](area.nl);nwr[shop=tyres](area.nl););
out center tags;"""
RDW_COMPANIES = "https://opendata.rdw.nl/resource/5k74-3jha.json"
RDW_ACCREDITATIONS = "https://opendata.rdw.nl/resource/nmwb-dqkz.json"
OUT = Path(__file__).resolve().parent.parent / "data" / "garages.json"
FIELDS = ["name", "lat", "lon", "street", "city", "type", "brand", "website", "phone", "hours", "apk"]
MIN_ROWS = 2000  # minder = de export is mislukt; dan het oude bestand houden
UA = {"User-Agent": "Carvital garage export"}


def get_json(url, data=None, timeout=120):
    req = urllib.request.Request(url, data=data, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def load_osm(argv):
    if len(argv) > 1:
        return json.loads(Path(argv[1]).read_text(encoding="utf-8"))
    body = urllib.parse.urlencode({"data": QUERY}).encode()
    return get_json(OVERPASS, data=body, timeout=700)


def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def house_no(s):
    m = re.match(r"\s*(\d+)", s or "")
    return m.group(1) if m else ""


def load_apk_keys():
    """Sleutels (postcode+huisnummer, straat+huisnummer+plaats, naam+plaats) van APK-erkende bedrijven."""
    q = urllib.parse.urlencode({"erkenning": "APK Lichte voertuigen", "$select": "volgnummer", "$limit": 50000})
    apk_ids = {r["volgnummer"] for r in get_json(f"{RDW_ACCREDITATIONS}?{q}")}
    q = urllib.parse.urlencode({"$limit": 100000})
    keys = set()
    for c in get_json(f"{RDW_COMPANIES}?{q}", timeout=300):
        if c.get("volgnummer") not in apk_ids:
            continue
        hn = house_no(c.get("huisnummer"))
        pc = norm(c.get("postcode_numeriek", "") + c.get("postcode_alfanumeriek", ""))
        city = norm(c.get("plaats"))
        if pc and hn:
            keys.add(("pc", pc, hn))
        if hn:
            keys.add(("st", norm(c.get("straat")), hn, city))
        for name in (c.get("naam_bedrijf"), c.get("gevelnaam")):
            if name:
                keys.add(("nm", norm(name), city))
    print(f"{len(apk_ids)} APK-erkende bedrijven bij de RDW")
    return keys


def is_apk(t, keys):
    hn = house_no(t.get("addr:housenumber"))
    city = norm(t.get("addr:city"))
    if hn:  # met huisnummer alleen op adres matchen, zodat een ander filiaal van een keten niet meetelt
        return ("pc", norm(t.get("addr:postcode")), hn) in keys or ("st", norm(t.get("addr:street")), hn, city) in keys
    return ("nm", norm(t.get("name")), city) in keys


def row(el, keys):
    t = el.get("tags", {})
    lat = el.get("lat", el.get("center", {}).get("lat"))
    lon = el.get("lon", el.get("center", {}).get("lon"))
    if not t.get("name") or lat is None:
        return None
    street = " ".join(x for x in (t.get("addr:street"), t.get("addr:housenumber")) if x)
    phone = (t.get("phone") or t.get("contact:phone") or "").split(";")[0].strip()
    return [
        t["name"].strip(),
        round(lat, 5),
        round(lon, 5),
        street,
        t.get("addr:city", ""),
        "t" if t.get("shop") == "tyres" else "r",
        t.get("brand", ""),
        t.get("website") or t.get("contact:website") or "",
        phone,
        (t.get("opening_hours") or "")[:80],
        1 if is_apk(t, keys) else 0,
    ]


def main(argv):
    keys = load_apk_keys()
    rows = [r for r in (row(el, keys) for el in load_osm(argv)["elements"]) if r]
    # dezelfde zaak kan als punt en als gebouw voorkomen: dubbele naam+locatie eruit
    seen, unique = set(), []
    for r in rows:
        key = (r[0].lower(), round(r[1], 3), round(r[2], 3))
        if key not in seen:
            seen.add(key)
            unique.append(r)
    if len(unique) < MIN_ROWS:
        sys.exit(f"Maar {len(unique)} garages gevonden; de export is waarschijnlijk mislukt. Oud bestand blijft staan.")
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps({
        "updated": date.today().isoformat(),
        "attribution": "© OpenStreetMap contributors, ODbL (https://www.openstreetmap.org/copyright); APK: RDW Open Data",
        "fields": FIELDS,
        "rows": unique,
    }, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"{len(unique)} garages written to {OUT}, {sum(r[-1] for r in unique)} APK-erkend")


if __name__ == "__main__":
    main(sys.argv)
