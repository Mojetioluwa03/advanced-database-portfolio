#!/usr/bin/env python3
"""Generate the physical ER diagram from the live schema.

Reads tables, columns, primary keys and foreign keys from pg_catalog (which,
unlike information_schema.constraint_column_usage, reports composite foreign
keys correctly) and writes two files into this directory:

    physical_crowfoot.mmd   Mermaid source - renders directly on GitHub
    physical_crowfoot.svg   standalone vector export, no external assets

The diagram is derived from the database rather than drawn by hand, so it
cannot drift from schema.sql. Re-run it after any schema change:

    python generate_erd.py                 # uses the portable cluster on 5433
    PGPORT=5432 python generate_erd.py
"""

from __future__ import annotations

import os
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

# --- connection ---------------------------------------------------------------

def psql_binary() -> str:
    explicit = os.environ.get("PSQL_BIN")
    if explicit:
        return explicit
    here = os.path.dirname(os.path.abspath(__file__))
    candidate = os.path.join(here, "..", "..", "..", ".pg16", "pgsql", "bin", "psql")
    if os.path.exists(candidate) or os.path.exists(candidate + ".exe"):
        return os.path.abspath(candidate)
    return "psql"


def query(sql: str) -> list[list[str]]:
    cmd = [
        psql_binary(), "-X", "-q", "-A", "-F", "\x1f", "-t",
        "-v", "ON_ERROR_STOP=1",
        "-h", os.environ.get("PGHOST", "localhost"),
        "-p", os.environ.get("PGPORT", "5433"),
        "-U", os.environ.get("PGUSER", "postgres"),
        "-d", os.environ.get("PGDATABASE", "shopstack"),
        "-c", sql,
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return [line.split("\x1f") for line in out.splitlines() if line.strip()]


COLUMNS_SQL = """
SELECT c.relname,
       a.attnum,
       a.attname,
       format_type(a.atttypid, a.atttypmod),
       EXISTS (
           SELECT 1 FROM pg_index i
           WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY (i.indkey)
       )
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
WHERE n.nspname = 'public' AND c.relkind = 'r'
ORDER BY c.relname, a.attnum;
"""

FKS_SQL = """
SELECT con.conname,
       ch.relname,
       (
           SELECT string_agg(a.attname, ',' ORDER BY k.ord)
           FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
           JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
       ),
       pa.relname,
       (
           SELECT string_agg(a.attname, ',' ORDER BY k.ord)
           FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
           JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum
       )
FROM pg_constraint con
JOIN pg_class ch ON ch.oid = con.conrelid
JOIN pg_class pa ON pa.oid = con.confrelid
JOIN pg_namespace n ON n.oid = con.connamespace
WHERE con.contype = 'f' AND n.nspname = 'public'
ORDER BY ch.relname, con.conname;
"""

# --- model --------------------------------------------------------------------

SUBJECTS = {
    "Catalogue": ["brand", "category", "product", "product_category", "attribute",
                  "attribute_value", "product_variant", "variant_attribute_value"],
    "Supply and stock": ["supplier", "product_supplier", "warehouse", "stock_level",
                         "stock_movement"],
    "Commerce": ["customer", "customer_address", "cart", "cart_item", "promotion",
                 "customer_order", "order_line", "order_promotion", "payment",
                 "shipment", "shipment_line"],
    "After-sales": ["review", "return_request"],
}
PALETTE = {
    "Catalogue": ("#1d4ed8", "#dbeafe"),
    "Supply and stock": ("#047857", "#d1fae5"),
    "Commerce": ("#b45309", "#fef3c7"),
    "After-sales": ("#7e22ce", "#f3e8ff"),
}

TYPE_ABBREV = {
    "character varying": "varchar", "timestamp with time zone": "timestamptz",
    "double precision": "float8", "character": "char",
}


class Table:
    def __init__(self, name: str):
        self.name = name
        self.columns: list[tuple[str, str, bool]] = []   # (name, type, is_pk)
        self.fk_cols: set[str] = set()
        self.layer = 0
        self.x = self.y = 0.0
        self.width = self.height = 0.0

    @property
    def subject(self) -> str:
        for subject, members in SUBJECTS.items():
            if self.name in members:
                return subject
        return "Commerce"


def short_type(raw: str) -> str:
    for long_name, short in TYPE_ABBREV.items():
        if raw.startswith(long_name):
            return short
    return raw


def load() -> tuple[dict[str, Table], list[dict]]:
    tables: dict[str, Table] = {}
    for table_name, _attnum, col, typ, is_pk in query(COLUMNS_SQL):
        tables.setdefault(table_name, Table(table_name))
        tables[table_name].columns.append((col, short_type(typ), is_pk == "t"))

    fks = []
    for conname, child, child_cols, parent, parent_cols in query(FKS_SQL):
        fks.append({"name": conname, "child": child, "child_cols": child_cols.split(","),
                    "parent": parent, "parent_cols": parent_cols.split(",")})
        tables[child].fk_cols.update(child_cols.split(","))
    return tables, fks


def assign_layers(tables: dict[str, Table], fks: list[dict]) -> None:
    parents = defaultdict(list)
    for fk in fks:
        if fk["child"] != fk["parent"]:          # ignore the category self-reference
            parents[fk["child"]].append(fk["parent"])

    def depth(name: str) -> int:
        stack = [(name, 0)]
        best = 0
        while stack:
            node, level = stack.pop()
            best = max(best, level)
            stack.extend((p, level + 1) for p in parents.get(node, []))
        return best

    for name, table in tables.items():
        table.layer = depth(name)


# --- layout -------------------------------------------------------------------

ROW_H, HEADER_H, PAD, GAP_X, GAP_Y = 15.0, 26.0, 6.0, 110.0, 26.0
CHAR_W = 6.1
MIN_W = 186.0


def size_boxes(tables: dict[str, Table]) -> None:
    for table in tables.values():
        widest = max(
            (len(f"{col}  {typ}") + (6 if col in table.fk_cols else 0)
             for col, typ, _ in table.columns),
            default=12,
        )
        table.width = max(MIN_W, PAD * 2 + CHAR_W * widest + 38)
        table.height = HEADER_H + ROW_H * len(table.columns) + PAD


def order_within_layers(tables: dict[str, Table], fks: list[dict]) -> dict[int, list[Table]]:
    layers: dict[int, list[Table]] = defaultdict(list)
    for table in sorted(tables.values(), key=lambda t: t.name):
        layers[table.layer].append(table)

    # One barycenter sweep: put each table near the average height of its
    # parents, which removes most edge crossings without a full Sugiyama pass.
    for depth in sorted(layers)[1:]:
        index = {t.name: i for i, t in enumerate(layers[depth - 1])}
        def key(table: Table) -> float:
            ys = [index[fk["parent"]] for fk in fks
                  if fk["child"] == table.name and fk["parent"] in index]
            return sum(ys) / len(ys) if ys else len(layers[depth - 1])
        layers[depth].sort(key=key)
    return layers


def place(layers: dict[int, list[Table]]) -> tuple[float, float]:
    total_h = max(sum(t.height for t in group) + GAP_Y * (len(group) - 1)
                  for group in layers.values())
    x = 40.0
    for depth in sorted(layers):
        group = layers[depth]
        height = sum(t.height for t in group) + GAP_Y * (len(group) - 1)
        y = 96.0 + (total_h - height) / 2
        for table in group:
            table.x, table.y = x, y
            y += table.height + GAP_Y
        x += max(t.width for t in group) + GAP_X
    return x - GAP_X + 40.0, total_h + 96.0 + 60.0


# --- svg ----------------------------------------------------------------------

def esc(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;"))


def row_y(table: Table, column: str) -> float:
    for i, (col, _typ, _pk) in enumerate(table.columns):
        if col == column:
            return table.y + HEADER_H + ROW_H * i + ROW_H / 2
    return table.y + table.height / 2


# --- edge routing ---------------------------------------------------------------

LANE_PAD, LANE_STEP, CH_STEP = 16.0, 9.5, 11.0


def column_spans(tables: dict[str, Table]) -> tuple[list[tuple[float, float]], dict[float, int]]:
    by_x: dict[float, list[Table]] = defaultdict(list)
    for table in tables.values():
        by_x[round(table.x, 1)].append(table)
    xs = sorted(by_x)
    return ([(x, x + max(t.width for t in by_x[x])) for x in xs],
            {x: i for i, x in enumerate(xs)})


def crosses_box(y: float, x0: float, x1: float, boxes: list[Table]) -> bool:
    lo, hi = min(x0, x1), max(x0, x1)
    return any(b.y + 1 < y < b.y + b.height - 1 and min(hi, b.x + b.width) > max(lo, b.x) + 1
               for b in boxes)


def plan_routes(tables: dict[str, Table], fks: list[dict]) -> tuple[list[dict], float]:
    """Orthogonal routing that keeps vertical runs in the gaps between columns.

    Each edge leaves the child's FK row, turns into a lane inside a column gap,
    runs vertically there, then enters the parent at the referenced row. Lanes are
    spaced so two relationships never draw on top of each other. An edge whose
    horizontal leg would still cut through a third table is detoured along a
    channel below the diagram instead.
    """
    boxes = list(tables.values())
    spans, col_index = column_spans(tables)
    gaps = [(spans[k][1], spans[k + 1][0]) for k in range(len(spans) - 1)]
    bottom = max(b.y + b.height for b in boxes)

    routes: list[dict] = []
    for fk in fks:
        child, parent = tables[fk["child"]], tables[fk["parent"]]
        cy = sum(row_y(child, c) for c in fk["child_cols"]) / len(fk["child_cols"])
        py = sum(row_y(parent, c) for c in fk["parent_cols"]) / len(fk["parent_cols"])
        route = {"fk": fk, "child": child, "parent": parent, "cy": cy, "py": py,
                 "cx": child.x, "px": parent.x + parent.width}
        routes.append(route)
        if child is parent:
            route["kind"] = "self"
            continue

        route["kind"] = "orth"
        i, j = col_index[round(child.x, 1)], col_index[round(parent.x, 1)]
        ideal = (route["cx"] + route["px"]) / 2
        best, best_key = None, None
        for k in range(j, i):
            lo, hi = gaps[k]
            # score against both edges of the gap: any lane inside it is then free too
            score = (int(crosses_box(cy, route["cx"], lo, boxes))
                     + int(crosses_box(cy, route["cx"], hi, boxes))
                     + int(crosses_box(py, lo, route["px"], boxes))
                     + int(crosses_box(py, hi, route["px"], boxes)))
            key = (score, abs((lo + hi) / 2 - ideal))
            if best is None or key < best_key:
                best, best_key = k, key
        route["channel"] = best_key[0] > 0
        # a channelled edge leaves into the gap beside the child and re-enters
        # beside the parent, so both short horizontals stay out of other tables
        route["gap"] = (i - 1) if route["channel"] else best
        route["gap_parent"] = j

    channel_edges = sorted((r for r in routes if r.get("channel")), key=lambda r: (r["py"], r["cy"]))
    for n, route in enumerate(channel_edges):
        route["ch_y"] = bottom + 30.0 + n * CH_STEP

    # hand out one lane per relationship inside each gap
    requests: dict[int, list[tuple]] = defaultdict(list)
    for route in routes:
        if route["kind"] != "orth":
            continue
        requests[route["gap"]].append((route, route["py"], route["cy"], "lane_child"))
        if route["channel"]:
            requests[route["gap_parent"]].append((route, route["py"], route["cy"], "lane_parent"))
    for gap, items in requests.items():
        left, right = gaps[gap]
        usable = max(right - left - 2 * LANE_PAD, 8.0)
        items.sort(key=lambda it: (it[1], it[2]))
        step = min(LANE_STEP, usable / max(len(items) - 1, 1))
        for n, (route, *_rest, field) in enumerate(items):
            route[field] = left + LANE_PAD + n * step

    min_height = (max(r["ch_y"] for r in channel_edges) + 85.0) if channel_edges else 0.0
    return routes, min_height


def render_svg(tables: dict[str, Table], routes: list[dict], n_fks: int,
               width: float, height: float) -> str:
    out: list[str] = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" height="{height:.0f}" '
        f'viewBox="0 0 {width:.0f} {height:.0f}" font-family="Segoe UI, Helvetica, Arial, sans-serif">',
        '<defs><style>'
        '.col{font-size:10.5px;fill:#0f172a}'
        '.typ{font-size:10.5px;fill:#64748b}'
        '.hdr{font-size:12px;font-weight:600;fill:#ffffff}'
        '.key{font-size:8.5px;font-weight:700}'
        '.edge{fill:none;stroke:#475569;stroke-width:1.15;opacity:.72}'
        '.tick{stroke:#475569;stroke-width:1.15}'
        '</style></defs>',
        f'<rect width="100%" height="100%" fill="#ffffff"/>',
        '<text x="40" y="42" font-size="22" font-weight="700" fill="#0f172a">'
        'ShopStack — physical data model</text>',
        '<text x="40" y="66" font-size="12.5" fill="#475569">'
        f'{len(tables)} tables, {n_fks} foreign keys · generated from pg_catalog by '
        'erd/generate_erd.py</text>',
    ]

    # edges first, so boxes sit on top of the lines
    for route in routes:
        child, parent = route["child"], route["parent"]
        cy, py, cx, px = route["cy"], route["py"], route["cx"], route["px"]

        if route["kind"] == "self":                           # category self-reference
            x0 = child.x + child.width
            out.append(
                f'<path class="edge" d="M {x0:.1f} {cy:.1f} C {x0 + 46:.1f} {cy - 10:.1f}, '
                f'{x0 + 46:.1f} {child.y - 14:.1f}, {x0 - 30:.1f} {child.y - 14:.1f} '
                f'L {x0 - 60:.1f} {child.y - 14:.1f} L {x0 - 60:.1f} {child.y + 8:.1f}"/>')
            out.append(f'<path class="tick" d="M {x0 - 66:.1f} {child.y + 8:.1f} '
                       f'L {x0 - 54:.1f} {child.y + 8:.1f}"/>')
            continue

        lane = route["lane_child"]
        pts = [(cx, cy), (lane, cy)]
        if route["channel"]:
            outer = route["lane_parent"]
            pts += [(lane, route["ch_y"]), (outer, route["ch_y"]), (outer, py)]
        else:
            pts.append((lane, py))
        pts.append((px, py))
        out.append('<path class="edge" d="M ' +
                   ' L '.join(f'{x:.1f} {y:.1f}' for x, y in pts) + '"/>')
        # one-and-only-one: a tick across the parent end
        out.append(f'<path class="tick" d="M {px + 12:.1f} {py - 5:.1f} L {px + 12:.1f} {py + 5:.1f}"/>')
        # zero-or-many: crow's foot at the child end
        out.append(f'<path class="tick" d="M {cx - 13:.1f} {cy:.1f} L {cx:.1f} {cy - 5.5:.1f} '
                   f'M {cx - 13:.1f} {cy:.1f} L {cx:.1f} {cy + 5.5:.1f} '
                   f'M {cx - 13:.1f} {cy:.1f} L {cx:.1f} {cy:.1f}"/>')

    # boxes
    for table in sorted(tables.values(), key=lambda t: (t.x, t.y)):
        fill, tint = PALETTE[table.subject]
        out.append(f'<g><rect x="{table.x:.1f}" y="{table.y:.1f}" width="{table.width:.1f}" '
                   f'height="{table.height:.1f}" rx="5" fill="#ffffff" stroke="#94a3b8"/>')
        out.append(f'<path d="M {table.x:.1f} {table.y + HEADER_H:.1f} '
                   f'L {table.x:.1f} {table.y + 5:.1f} Q {table.x:.1f} {table.y:.1f} '
                   f'{table.x + 5:.1f} {table.y:.1f} L {table.x + table.width - 5:.1f} {table.y:.1f} '
                   f'Q {table.x + table.width:.1f} {table.y:.1f} {table.x + table.width:.1f} {table.y + 5:.1f} '
                   f'L {table.x + table.width:.1f} {table.y + HEADER_H:.1f} Z" fill="{fill}"/>')
        out.append(f'<text class="hdr" x="{table.x + PAD:.1f}" y="{table.y + 17.5:.1f}">'
                   f'{esc(table.name)}</text>')
        for i, (col, typ, is_pk) in enumerate(table.columns):
            ty = table.y + HEADER_H + ROW_H * i + 11
            is_fk = col in table.fk_cols
            if is_pk and is_fk:
                tag, colour = "PK·FK", "#b45309"
            elif is_pk:
                tag, colour = "PK", "#b45309"
            elif is_fk:
                tag, colour = "FK", "#1d4ed8"
            else:
                tag, colour = "", "#94a3b8"
            if tag:
                out.append(f'<text class="key" x="{table.x + PAD:.1f}" y="{ty:.1f}" '
                           f'fill="{colour}">{tag}</text>')
            out.append(f'<text class="col" x="{table.x + PAD + 30:.1f}" y="{ty:.1f}">{esc(col)}</text>')
            out.append(f'<text class="typ" x="{table.x + table.width - PAD:.1f}" y="{ty:.1f}" '
                       f'text-anchor="end">{esc(typ)}</text>')
        out.append(f'<rect x="{table.x:.1f}" y="{table.y:.1f}" width="{table.width:.1f}" '
                   f'height="{table.height:.1f}" rx="5" fill="none" stroke="#64748b" '
                   f'stroke-width="1.1"/></g>')

    # legend
    lx, ly = 40.0, height - 34.0
    out.append(f'<g><text x="{lx}" y="{ly}" font-size="10.5" fill="#475569">'
               'PK primary key · FK foreign key · PK·FK both · crow\'s foot = zero or many · '
               'tick = exactly one · colours = subject area</text>')
    for i, (subject, (fill, _tint)) in enumerate(PALETTE.items()):
        bx = lx + i * 150
        out.append(f'<rect x="{bx}" y="{ly + 8}" width="11" height="11" rx="2" fill="{fill}"/>')
        out.append(f'<text x="{bx + 17}" y="{ly + 17}" font-size="10.5" fill="#334155">'
                   f'{esc(subject)}</text>')
    out.append('</g></svg>')
    return "\n".join(out)


# --- mermaid ------------------------------------------------------------------

def render_mermaid(tables: dict[str, Table], fks: list[dict]) -> str:
    lines = ["%% ShopStack physical model - generated by erd/generate_erd.py",
             "%% Renders natively on GitHub. Regenerate after any schema change.",
             "erDiagram"]
    for table in sorted(tables.values(), key=lambda t: t.name):
        lines.append(f"  {table.name} {{")
        for col, typ, is_pk in table.columns:
            marks = []
            if is_pk:
                marks.append("PK")
            if col in table.fk_cols:
                marks.append("FK")
            suffix = f' "{", ".join(marks)}"' if marks else ""
            lines.append(f"    {typ.replace(' ', '_')} {col}{suffix}")
        lines.append("  }")
    for fk in fks:
        child, parent = fk["child"], fk["parent"]
        label = ",".join(fk["child_cols"])
        if child == parent:
            lines.append(f'  {parent} ||--o{{ {child} : "{label}"')
        else:
            lines.append(f'  {parent} ||--o{{ {child} : "{label}"')
    return "\n".join(lines) + "\n"


def main() -> int:
    tables, fks = load()
    if not tables:
        print("no tables found - is the database loaded?", file=sys.stderr)
        return 1

    size_boxes(tables)
    assign_layers(tables, fks)
    layers = order_within_layers(tables, fks)
    width, height = place(layers)
    routes, min_height = plan_routes(tables, fks)
    height = max(height, min_height)

    here = os.path.dirname(os.path.abspath(__file__))
    svg_path = os.path.join(here, "physical_crowfoot.svg")
    mmd_path = os.path.join(here, "physical_crowfoot.mmd")

    with open(svg_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(render_svg(tables, routes, len(fks), width, height))
    with open(mmd_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(render_mermaid(tables, fks))

    ET.parse(svg_path)                       # fail loudly on malformed XML
    channelled = sum(1 for r in routes if r.get("channel"))
    print(f"{len(tables)} tables, {len(fks)} foreign keys "
          f"({len(routes) - channelled} direct, {channelled} channelled)")
    print(f"wrote {svg_path}  ({width:.0f} x {height:.0f})")
    print(f"wrote {mmd_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
