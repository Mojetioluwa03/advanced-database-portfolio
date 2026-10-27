#!/usr/bin/env python3
"""
Offline integrity check for the ShopStack seed data.

Runs the same invariants that checks.sql runs inside PostgreSQL, but against the
CSV files. Useful when no database is available yet, and as a pre-load smoke
test that fails fast instead of surfacing an error halfway through COPY.

    python verify_seed.py

Exit code 0 = every check passed.
"""

from __future__ import annotations

import csv
import re
import sys
from collections import defaultdict
from decimal import Decimal
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE / "seed-data"
LOAD_SQL = HERE / "load.sql"

failures: list[str] = []


def fail(message: str) -> None:
    failures.append(message)


def read(name: str) -> list[dict[str, str]]:
    with open(DATA / f"{name}.csv", newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def check_headers() -> None:
    """Every \\copy column list must match its CSV header exactly."""
    text = LOAD_SQL.read_text(encoding="utf-8")
    pattern = re.compile(r"\\copy\s+(\w+)\s*\(([^)]*)\)\s+FROM\s+'([^']+)'")
    seen = 0
    for match in pattern.finditer(text):
        table, columns, path = match.groups()
        declared = [c.strip() for c in columns.split(",")]
        csv_path = HERE / path
        if not csv_path.exists():
            fail(f"{table}: missing file {path}")
            continue
        with open(csv_path, newline="", encoding="utf-8") as handle:
            header = next(csv.reader(handle))
        if header != declared:
            fail(f"{table}: header mismatch\n    load.sql: {declared}\n    csv:      {header}")
        seen += 1
    print(f"header check: {seen} \\copy statements compared against CSV headers")


def main() -> None:
    check_headers()

    variants = {row["variant_id"] for row in read("product_variant")}
    products = {row["product_id"] for row in read("product")}
    brands = {row["brand_id"] for row in read("brand")}
    categories = {row["category_id"] for row in read("category")}
    customers = {row["customer_id"] for row in read("customer")}

    # -- catalogue ---------------------------------------------------------
    for row in read("product"):
        if row["brand_id"] not in brands:
            fail(f"product {row['product_id']} references missing brand {row['brand_id']}")
    for row in read("product_category"):
        if row["category_id"] not in categories:
            fail(f"product_category references missing category {row['category_id']}")
    for row in read("product_variant"):
        if row["product_id"] not in products:
            fail(f"variant {row['variant_id']} references missing product {row['product_id']}")
        if Decimal(row["price"]) <= 0:
            fail(f"variant {row['variant_id']} has non-positive price")

    # -- customers and addresses -------------------------------------------
    defaults: dict[str, int] = defaultdict(int)
    for row in read("customer_address"):
        if row["customer_id"] not in customers:
            fail(f"address {row['address_id']} references missing customer")
        if row["is_default"] == "true":
            defaults[row["customer_id"]] += 1
    for customer_id, count in defaults.items():
        if count > 1:
            fail(f"customer {customer_id} has {count} default addresses")

    # -- orders, lines and totals ------------------------------------------
    orders = read("customer_order")
    line_totals: dict[str, Decimal] = defaultdict(Decimal)
    line_keys: set[int] = set()
    line_lines = 0
    for row in read("order_line"):
        line_lines += 1
        quantity = int(row["quantity"])
        unit_price = Decimal(row["unit_price"])
        line_total = Decimal(row["line_total"])
        if line_total != quantity * unit_price:
            fail(f"order_line {row['order_id']}/{row['variant_id']}: "
                 f"line_total {line_total} != {quantity} x {unit_price}")
        if row["variant_id"] not in variants:
            fail(f"order_line references missing variant {row['variant_id']}")
        line_totals[row["order_id"]] += line_total
        line_keys.add(int(row["order_id"]) * 10_000_000 + int(row["variant_id"]))

    order_ids = {row["order_id"] for row in orders}
    settled: dict[str, Decimal] = defaultdict(Decimal)
    by_status: dict[str, str] = {}
    for row in orders:
        order_id = row["order_id"]
        by_status[order_id] = row["status"]
        if row["customer_id"] not in customers:
            fail(f"order {order_id} references missing customer")
        subtotal = Decimal(row["subtotal"])
        discount = Decimal(row["discount_total"])
        shipping = Decimal(row["shipping_total"])
        tax = Decimal(row["tax_total"])
        grand = Decimal(row["grand_total"])
        if subtotal != line_totals[order_id]:
            fail(f"order {order_id}: subtotal {subtotal} != sum of lines {line_totals[order_id]}")
        expected = subtotal - discount + shipping + tax
        if grand != expected:
            fail(f"order {order_id}: grand_total {grand} != {expected}")
        if discount > subtotal:
            fail(f"order {order_id}: discount exceeds subtotal")

    for order_id in line_totals:
        if order_id not in order_ids:
            fail(f"order_line references missing order {order_id}")

    # -- payments ----------------------------------------------------------
    for row in read("payment"):
        if row["order_id"] not in order_ids:
            fail(f"payment {row['payment_id']} references missing order")
        if row["status"] in ("paid", "refunded"):
            settled[row["order_id"]] += Decimal(row["amount"])
    for row in orders:
        if row["status"] in ("paid", "shipped", "delivered", "refunded"):
            if settled[row["order_id"]] != Decimal(row["grand_total"]):
                fail(f"order {row['order_id']}: payments {settled[row['order_id']]} "
                     f"!= grand_total {row['grand_total']}")

    # -- shipments and returns must point at real order lines --------------
    for name, key in (("shipment_line", "shipment_line"), ("return_request", "return_request")):
        for row in read(name):
            composite = int(row["order_id"]) * 10_000_000 + int(row["variant_id"])
            if composite not in line_keys:
                fail(f"{key} references missing order_line "
                     f"{row['order_id']}/{row['variant_id']}")

    # -- inventory ledger --------------------------------------------------
    ledger: dict[tuple[str, str], int] = defaultdict(int)
    for row in read("stock_movement"):
        ledger[(row["variant_id"], row["warehouse_id"])] += int(row["delta"])
        if row["reason"] == "sale" and not row["ref_order_id"]:
            fail(f"movement {row['movement_id']}: sale without an order reference")
    for row in read("stock_level"):
        key = (row["variant_id"], row["warehouse_id"])
        if int(row["quantity"]) != ledger.get(key, 0):
            fail(f"stock_level {key}: {row['quantity']} != ledger {ledger.get(key, 0)}")
        if int(row["quantity"]) < 0:
            fail(f"stock_level {key}: negative quantity")

    # -- reviews -----------------------------------------------------------
    seen_reviews: set[tuple[str, str]] = set()
    for row in read("review"):
        key = (row["customer_id"], row["product_id"])
        if key in seen_reviews:
            fail(f"duplicate review for customer/product {key}")
        seen_reviews.add(key)
        if row["product_id"] not in products:
            fail(f"review references missing product {row['product_id']}")

    print(f"checked: {len(orders)} orders, {line_lines} order lines, "
          f"{len(variants)} variants, {len(customers)} customers")

    if failures:
        print(f"\nFAILED ({len(failures)} problems)")
        for message in failures[:40]:
            print(f"  - {message}")
        if len(failures) > 40:
            print(f"  ... and {len(failures) - 40} more")
        sys.exit(1)

    print("all checks passed")


if __name__ == "__main__":
    main()
