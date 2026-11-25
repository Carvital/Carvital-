"""Build data/garages.json: all car repair and tyre shops in the Netherlands from OpenStreetMap.

The site searches this file in the browser, so a garage search never depends on a live
(and often overloaded) Overpass server and no visitor location leaves the browser.

Run it again now and then to refresh the data:
    python scripts/build_garages.py              # downloads from Overpass (can take minutes)
    python scripts/build_garages.py export.json  # uses an Overpass JSON export you already have

Data: (c) OpenStreetMap contributors, available under the Open Database License (ODbL).
"""
import json
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
OUT = Path(__file__).resolve().parent.parent / "data" / "garages.json"
FIELDS = ["name", "lat", "lon", "street", "city", "type", "brand", "website", "phone", "hours"]


def load(argv):
    if len(argv) > 1:
        return json.loads(Path(argv[1]).read_text(encoding="utf-8"))
    body = urllib.parse.urlencode({"data": QUERY}).encode()
    req = urllib.request.Request(OVERPASS, data=body, headers={"User-Agent": "Carvital garage export"})
    with urllib.request.urlopen(req, timeout=700) as resp:
        return json.load(resp)


def row(el):
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
    ]


def main(argv):
    rows = [r for r in map(row, load(argv)["elements"]) if r]
    # dezelfde zaak kan als punt en als gebouw voorkomen: dubbele naam+locatie eruit
    seen, unique = set(), []
    for r in rows:
        key = (r[0].lower(), round(r[1], 3), round(r[2], 3))
        if key not in seen:
            seen.add(key)
            unique.append(r)
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps({
        "updated": date.today().isoformat(),
        "attribution": "© OpenStreetMap contributors, ODbL (https://www.openstreetmap.org/copyright)",
        "fields": FIELDS,
        "rows": unique,
    }, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"{len(unique)} garages written to {OUT}")


if __name__ == "__main__":
    main(sys.argv)
