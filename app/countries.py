# Produit app/countries.bin, les contours des pays surlignés sur la carte.
# Source : Natural Earth 1:50m, Admin 0 – Countries (domaine public)
#   https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_50m_admin_0_countries.geojson
# Usage, depuis le dossier du projet :
#   python3 app/countries.py ne_50m_admin_0_countries.geojson app/countries.bin
#
# Format (little endian) : pour chaque pays, code ISO sur 2 octets, nombre de
# contours (UInt16), puis pour chaque contour le nombre de points (UInt16) et
# les points en centièmes de degré (Int16 latitude, Int16 longitude).
import json, struct, sys

TOLERANCE = 0.03      # degrés : simplification invisible à l'échelle d'un pays
MIN_AREA = 0.02       # degrés carrés : îlots ignorés, sauf pour les petits pays


def simplify(points, tolerance):
    """Douglas-Peucker, sans récursion"""
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        (x1, y1), (x2, y2) = points[first], points[last]
        dx, dy = x2 - x1, y2 - y1
        length = (dx * dx + dy * dy) ** 0.5
        far, index = 0.0, None
        for i in range(first + 1, last):
            x, y = points[i]
            d = abs(dy * (x - x1) - dx * (y - y1)) / length if length else ((x - x1) ** 2 + (y - y1) ** 2) ** 0.5
            if d > far:
                far, index = d, i
        if index is not None and far > tolerance:
            keep[index] = True
            stack += [(first, index), (index, last)]
    return [p for p, k in zip(points, keep) if k]


def area(ring):
    return abs(sum(x1 * y2 - x2 * y1 for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]))) / 2


features = json.load(open(sys.argv[1]))["features"]
countries = {}
for feature in features:
    code = feature["properties"]["ISO_A2_EH"]
    if len(code) != 2 or not code.isalpha():
        continue
    geometry = feature["geometry"]
    polygons = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
    # Contour extérieur seulement : les enclaves sont dessinées par leur propre pays
    countries.setdefault(code, []).extend(polygon[0] for polygon in polygons)

out = bytearray()
for code, rings in sorted(countries.items()):
    rings = [[(lon, lat) for lon, lat in ring[:-1]] for ring in rings]
    largest = max(area(r) for r in rings)
    rings = [r for r in rings if area(r) >= min(MIN_AREA, largest * 0.5)]
    # Un pays minuscule (Monaco) garde son contour d'origine
    rings = [s if len(s := simplify(r + r[:1], TOLERANCE)[:-1]) >= 3 else r for r in rings]
    out += code.encode() + struct.pack("<H", len(rings))
    for ring in rings:
        out += struct.pack("<H", len(ring))
        for lon, lat in ring:
            out += struct.pack("<hh", round(lat * 100), round(lon * 100))
open(sys.argv[2], "wb").write(out)
print(f"{len(countries)} pays, {len(out)} octets")
