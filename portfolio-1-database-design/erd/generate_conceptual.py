#!/usr/bin/env python3
"""Draw the conceptual model in Chen notation.

The conceptual model is a design artefact, not a database read-out, so the
entities, relationships and cardinalities below are declared by hand. They are
the ones argued in ../README.md section 2; the mapping down to tables is in
README.md in this directory.

    python generate_conceptual.py      # writes conceptual_chen.svg

Notation: rectangle = entity, ellipse = attribute (underlined = key),
diamond = relationship, 1 / N / M on the connector = participation.

Key attributes are placed automatically: for each entity the script scores
candidate positions around the box against every relationship connector and
every other shape, and keeps the roomiest one, so an attribute ellipse never
lands on top of a line or a neighbouring diamond.
"""

from __future__ import annotations

import os
import xml.etree.ElementTree as ET
from math import atan2, cos, degrees, hypot, radians, sin

W, H = 1980, 1130
DY = 60.0                                   # clears the title band
ENTITY_W, ENTITY_H = 168.0, 46.0
DIA_RX, DIA_RY = 66.0, 34.0

INK = "#0f172a"
LINE = "#475569"
KEY_FILL = "#fef9c3"
SUBJECT = {
    "Catalogue": ("#dbeafe", "#1d4ed8"),
    "Supply and stock": ("#d1fae5", "#047857"),
    "Commerce": ("#fef3c7", "#b45309"),
    "After-sales": ("#f3e8ff", "#7e22ce"),
}

# entity -> (cx, cy, subject, key attribute)
ENTITIES = {
    "BRAND":      (160, 150, "Catalogue", "brand_id"),
    "SUPPLIER":   (160, 380, "Supply and stock", "supplier_id"),
    "WAREHOUSE":  (160, 610, "Supply and stock", "warehouse_id"),
    "ATTRIBUTE":  (160, 840, "Catalogue", "attribute_id"),
    "PRODUCT":    (620, 300, "Catalogue", "product_id"),
    "VARIANT":    (620, 620, "Catalogue", "sku"),
    "CATEGORY":   (1120, 150, "Catalogue", "category_id"),
    "CUSTOMER":   (1120, 560, "Commerce", "customer_id"),
    "CART":       (1480, 220, "Commerce", "cart_id"),
    "ORDER":      (1480, 560, "Commerce", "order_id"),
    "ORDER_LINE": (1080, 860, "Commerce", "order_line_id"),
    "PROMOTION":  (1480, 860, "Commerce", "promotion_id"),
    "PAYMENT":    (1830, 330, "Commerce", "payment_id"),
    "SHIPMENT":   (1830, 720, "Commerce", "shipment_id"),
    "RETURN":     (1830, 1000, "After-sales", "return_id"),
}

# (verb, entity a, card a, entity b, card b, diamond centre, relationship attributes)
RELATIONSHIPS = [
    ("makes",         "BRAND",      "1", "PRODUCT",     "N", (390, 225), ()),
    ("supplies",      "SUPPLIER",   "M", "PRODUCT",     "N", (390, 340), ("unit_cost", "lead_time_days")),
    ("stocked at",    "WAREHOUSE",  "M", "VARIANT",     "N", (390, 615), ("quantity", "reorder_point")),
    ("described by",  "ATTRIBUTE",  "N", "VARIANT",     "M", (390, 730), ("value",)),
    ("has",           "PRODUCT",    "1", "VARIANT",     "N", (620, 460), ()),
    ("classified as", "PRODUCT",    "M", "CATEGORY",    "N", (870, 225), ()),
    ("reviews",       "CUSTOMER",   "M", "PRODUCT",     "N", (870, 430), ("rating",)),
    ("holds",         "CART",       "M", "VARIANT",     "N", (1050, 420), ("quantity",)),
    ("owns",          "CUSTOMER",   "1", "CART",        "N", (1300, 390), ()),
    ("places",        "CUSTOMER",   "1", "ORDER",       "N", (1300, 560), ()),
    ("paid by",       "ORDER",      "1", "PAYMENT",     "N", (1655, 445), ()),
    ("fulfilled by",  "ORDER",      "1", "SHIPMENT",    "N", (1655, 640), ()),
    ("contains",      "ORDER",      "1", "ORDER_LINE",  "N", (1280, 710), ()),
    ("applies",       "ORDER",      "M", "PROMOTION",   "N", (1480, 710), ("discount_applied",)),
    ("refers to",     "ORDER_LINE", "N", "VARIANT",     "1", (850, 740), ()),
    ("against",       "RETURN",     "N", "ORDER_LINE",  "1", (1440, 950), ()),
]


def y(v: float) -> float:
    return v + DY


def esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def ellipse_rx(text: str, minimum: float = 42.0) -> float:
    return max(minimum, len(text) * 3.05 + 11)


def box_edge(cx: float, cy: float, tx: float, ty: float) -> tuple[float, float]:
    dx, dy = tx - cx, ty - cy
    sx = (ENTITY_W / 2) / abs(dx) if dx else float("inf")
    sy = (ENTITY_H / 2) / abs(dy) if dy else float("inf")
    s = min(sx, sy)
    return cx + dx * s, cy + dy * s


def rect_point_distance(px: float, py: float, rx: float, ry: float) -> float:
    dx, dy = abs(px) - rx, abs(py) - ry
    if dx > 0 or dy > 0:
        return hypot(max(dx, 0), max(dy, 0))
    return -min(-dx, -dy)


def segment_rect_clearance(ax, ay, bx, by, rx, ry, rcx, rcy, samples=24) -> float:
    """Smallest gap between a segment and a rectangle (negative = overlap)."""
    best = float("inf")
    for i in range(samples + 1):
        t = i / samples
        px = ax + (bx - ax) * t - rcx
        py = ay + (by - ay) * t - rcy
        best = min(best, rect_point_distance(px, py, rx, ry))
    return best


def build_segments() -> list[tuple[float, float, float, float]]:
    segs = []
    for _verb, ea, _ca, eb, _cb, (dx, dy_), _attrs in RELATIONSHIPS:
        ax, ay = ENTITIES[ea][0], y(ENTITIES[ea][1])
        bx, by = ENTITIES[eb][0], y(ENTITIES[eb][1])
        dyy = y(dy_)
        segs.append((*box_edge(ax, ay, dx, dyy), dx, dyy))
        segs.append((dx, dyy, *box_edge(bx, by, dx, dyy)))
    return segs


def place_key_attributes(segments) -> dict[str, tuple[float, float]]:
    shapes = []                      # (cx, cy, rx, ry) of things to keep away from
    for name, (cx, cy, _s, _k) in ENTITIES.items():
        shapes.append((cx, y(cy), ENTITY_W / 2, ENTITY_H / 2))
    for _v, _a, _ca, _b, _cb, (dx, dy_), _at in RELATIONSHIPS:
        shapes.append((dx, y(dy_), DIA_RX, DIA_RY))

    degree = {n: 0 for n in ENTITIES}
    for _v, ea, _ca, eb, _cb, _d, _at in RELATIONSHIPS:
        degree[ea] += 1
        degree[eb] += 1

    placed: dict[str, tuple[float, float]] = {}
    for name in sorted(ENTITIES, key=lambda n: -degree[n]):
        cx, cy = ENTITIES[name][0], y(ENTITIES[name][1])
        key = ENTITIES[name][3]
        rx, ry = ellipse_rx(key), 21.0
        best, best_score = None, -float("inf")
        for angle in range(0, 360, 15):
            ux, uy = cos(radians(angle)), sin(radians(angle))
            for reach in (0.0, 26.0, 52.0):
                px = cx + ux * (ENTITY_W / 2 + rx + 8 + reach)
                py = cy + uy * (ENTITY_H / 2 + ry + 6 + reach)
                if not (40 + rx < px < W - 40 - rx and 80 < py - ry and py + ry < H - 90):
                    continue
                score = 0.0
                for seg in segments:
                    score += min(segment_rect_clearance(*seg, rx, ry, px, py), 40.0)
                for sx, sy, srx, sry in shapes:
                    gap = max(abs(px - sx) - (rx + srx), abs(py - sy) - (ry + sry))
                    if gap < 0:
                        score -= 200.0
                    score += min(gap, 40.0) * 0.6
                for ex, ey in placed.values():
                    gap = max(abs(px - ex) - 2 * rx, abs(py - ey) - 2 * ry)
                    if gap < 0:
                        score -= 200.0
                if score > best_score:
                    best, best_score = (px, py), score
        placed[name] = best
        shapes.append((best[0], best[1], rx, ry))
    return placed


def diamond_points(cx: float, cy: float) -> str:
    return (f"{cx - DIA_RX:.1f},{cy:.1f} {cx:.1f},{cy - DIA_RY:.1f} "
            f"{cx + DIA_RX:.1f},{cy:.1f} {cx:.1f},{cy + DIA_RY:.1f}")


def card_label(x0, y0, x1, y1, t=0.42) -> tuple[float, float]:
    x, yy = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
    ang = atan2(y1 - y0, x1 - x0)
    return x - sin(ang) * 12, yy + cos(ang) * 12


def render() -> str:
    segments = build_segments()
    keys = place_key_attributes(segments)

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
        f'viewBox="0 0 {W} {H}" font-family="Segoe UI, Helvetica, Arial, sans-serif">',
        '<defs><style>'
        'text{font-size:11.5px;fill:#0f172a}'
        '.ent{font-size:12px;font-weight:600}'
        '.rel{font-size:10.5px;fill:#334155}'
        '.card{font-size:12px;font-weight:700;fill:#111827;'
        'paint-order:stroke;stroke:#ffffff;stroke-width:3px;stroke-linejoin:round}'
        '.attr{font-size:10.5px;fill:#0f172a;paint-order:stroke;stroke:#ffffff;stroke-width:3px;'
        'stroke-linejoin:round}'
        '.key{font-size:10.5px;font-weight:600;fill:#0f172a;text-decoration:underline;'
        'paint-order:stroke;stroke:#ffffff;stroke-width:3px}'
        '.line{stroke:#475569;stroke-width:1.1;fill:none}'
        '.shape{stroke-width:1.2}'
        '</style></defs>',
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        '<text x="40" y="40" font-size="22" font-weight="700" fill="#0f172a">'
        'ShopStack — conceptual model (Chen notation)</text>',
        '<text x="40" y="63" font-size="12.5" fill="#475569">'
        f'{len(ENTITIES)} entities, {len(RELATIONSHIPS)} relationships · key attributes '
        'underlined · cardinality shown at both ends of every connector</text>',
    ]

    # connectors, then shapes on top
    for _verb, ea, ca, eb, cb, (dx, dy_), _attrs in RELATIONSHIPS:
        ax, ay = ENTITIES[ea][0], y(ENTITIES[ea][1])
        bx, by = ENTITIES[eb][0], y(ENTITIES[eb][1])
        dyy = y(dy_)
        p0, p1 = box_edge(ax, ay, dx, dyy), box_edge(bx, by, dx, dyy)
        out.append(f'<path class="line" d="M {p0[0]:.1f} {p0[1]:.1f} L {dx:.1f} {dyy:.1f} '
                   f'L {p1[0]:.1f} {p1[1]:.1f}"/>')
        for (fx, fy), card in (((ax, ay), ca), ((bx, by), cb)):
            lx, ly = card_label(fx, fy, dx, dyy)
            out.append(f'<text class="card" x="{lx:.1f}" y="{ly + 4:.1f}" '
                       f'text-anchor="middle">{card}</text>')

    for name, (cx, cy, subject, key) in ENTITIES.items():
        fill, stroke = SUBJECT[subject]
        cy = y(cy)
        out.append(f'<rect x="{cx - ENTITY_W / 2:.1f}" y="{cy - ENTITY_H / 2:.1f}" '
                   f'width="{ENTITY_W}" height="{ENTITY_H}" rx="4" fill="{fill}" '
                   f'stroke="{stroke}" class="shape"/>')
        out.append(f'<text class="ent" x="{cx:.1f}" y="{cy + 4.5:.1f}" '
                   f'text-anchor="middle">{esc(name.replace("_", " "))}</text>')

        kx, ky = keys[name]
        rx = ellipse_rx(key)
        ox, oy = box_edge(cx, cy, kx, ky)
        out.append(f'<line class="line" x1="{ox:.1f}" y1="{oy:.1f}" x2="{kx:.1f}" y2="{ky:.1f}"/>')
        out.append(f'<ellipse cx="{kx:.1f}" cy="{ky:.1f}" rx="{rx:.1f}" ry="21" '
                   f'fill="{KEY_FILL}" stroke="{stroke}" class="shape"/>')
        out.append(f'<text class="key" x="{kx:.1f}" y="{ky + 4:.1f}" text-anchor="middle">'
                   f'{esc(key)}</text>')

    for verb, _ea, _ca, _eb, _cb, (dx, dy_), attrs in RELATIONSHIPS:
        dyy = y(dy_)
        out.append(f'<polygon points="{diamond_points(dx, dyy)}" fill="#ffffff" '
                   f'stroke="{LINE}" class="shape"/>')
        words = verb.split()
        out.append(f'<text class="rel" x="{dx:.1f}" y="{dyy - (1 if len(words) > 1 else -4):.1f}" '
                   f'text-anchor="middle">{esc(words[0])}</text>')
        if len(words) > 1:
            out.append(f'<text class="rel" x="{dx:.1f}" y="{dyy + 12:.1f}" text-anchor="middle">'
                       f'{esc(" ".join(words[1:]))}</text>')
        for n, attr in enumerate(attrs):
            side = -1 if n % 2 == 0 else 1
            ax = dx + side * 96
            ay = dyy + DIA_RY + 34 + (n // 2) * 40
            rx = ellipse_rx(attr, 40)
            out.append(f'<line class="line" x1="{dx:.1f}" y1="{dyy + DIA_RY:.1f}" '
                       f'x2="{ax:.1f}" y2="{ay:.1f}"/>')
            out.append(f'<ellipse cx="{ax:.1f}" cy="{ay:.1f}" rx="{rx:.1f}" ry="18" '
                       f'fill="#ffffff" stroke="{LINE}" class="shape"/>')
            out.append(f'<text class="attr" x="{ax:.1f}" y="{ay + 3.5:.1f}" '
                       f'text-anchor="middle">{esc(attr)}</text>')

    # category self-reference
    cx, cy = ENTITIES["CATEGORY"][0], y(ENTITIES["CATEGORY"][1])
    out.append(f'<path class="line" d="M {cx - 30:.1f} {cy - ENTITY_H / 2:.1f} '
               f'C {cx - 44:.1f} {cy - 74:.1f}, {cx + 36:.1f} {cy - 74:.1f}, '
               f'{cx + 26:.1f} {cy - ENTITY_H / 2:.1f}"/>')
    out.append(f'<polygon points="{diamond_points(cx - 2, cy - 92)}" fill="#ffffff" '
               f'stroke="{LINE}" class="shape"/>')
    out.append(f'<text class="rel" x="{cx - 2:.1f}" y="{cy - 96:.1f}" text-anchor="middle">'
               f'<tspan x="{cx - 2:.1f}">parent</tspan>'
               f'<tspan x="{cx - 2:.1f}" dy="10">of</tspan></text>')
    out.append(f'<text class="card" x="{cx - 40:.1f}" y="{cy - 48:.1f}" text-anchor="middle">1</text>')
    out.append(f'<text class="card" x="{cx + 40:.1f}" y="{cy - 48:.1f}" text-anchor="middle">N</text>')

    ly = H - 52
    out.append(f'<text x="40" y="{ly}" font-size="10.5" fill="#475569">'
               'Chen notation: rectangle = entity · ellipse = attribute (underlined = key) · '
               'diamond = relationship · 1 / N / M = participation</text>')
    for i, (subject, (fill, stroke)) in enumerate(SUBJECT.items()):
        bx = 40 + i * 230
        out.append(f'<rect x="{bx}" y="{ly + 10}" width="11" height="11" rx="2" fill="{fill}" '
                   f'stroke="{stroke}"/>')
        out.append(f'<text x="{bx + 17}" y="{ly + 20}" font-size="10.5" fill="#334155">'
                   f'{esc(subject)}</text>')
    out.append(f'<text x="1000" y="{ly + 20}" font-size="10.5" fill="#475569">'
               'Non-key attributes are omitted for legibility; they are listed in schema.sql.</text>')
    out.append('</svg>')
    return "\n".join(out)


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "conceptual_chen.svg")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(render())
    ET.parse(path)
    print(f"wrote {path}  ({W} x {H})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
