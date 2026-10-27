"""Load the ShopStack catalogue into MongoDB as one document per product.

The source is the same CSV that seeded PostgreSQL in Portfolio 1, so both
stores describe the same 10,000 products and any comparison between them is
like for like.

This script only fabricates data - it runs no graded query and produces no
plan. The graded work is in queries/ (MQL) and model/ (design).

    python load_catalogue.py

The collection is dropped and rebuilt, so any indexes must be created
afterwards (model/indexes.js). That is deliberate: it makes the unindexed
baseline in plans/before/ reproducible by re-running this script.
"""

from __future__ import annotations

import argparse
import csv
import sys
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

from bson.decimal128 import Decimal128
from pymongo import MongoClient

HERE = Path(__file__).resolve().parent
DEFAULT_SEED = HERE.parent / "portfolio-1-database-design" / "seed-data"

# The seed CSVs write created_at as a naive local timestamp. Portfolio 1 loaded
# them into TIMESTAMPTZ without a session zone, so PostgreSQL resolved them with
# the server default, Africa/Lagos (UTC+1 all year, no DST). The same offset is
# applied here so that both stores hold the same instant rather than values an
# hour apart. The real fix is to emit ISO-8601 with an offset from seed.py,
# which would mean re-running the Portfolio 1 load; recorded, not done.
SEED_TIMEZONE = timezone(timedelta(hours=1))


def read_csv(seed: Path, name: str) -> list[dict[str, str]]:
    with open(seed / f"{name}.csv", newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def load_reference(seed: Path) -> tuple[dict, dict, dict]:
    brands = {int(r["brand_id"]): r["name"] for r in read_csv(seed, "brand")}

    raw_categories = read_csv(seed, "category")
    categories = {
        int(r["category_id"]): {
            "parent_id": int(r["parent_category_id"]) if r["parent_category_id"] else None,
            "name": r["name"],
            "slug": r["slug"],
        }
        for r in raw_categories
    }

    attributes = {int(r["attribute_id"]): r["name"] for r in read_csv(seed, "attribute")}
    # value_id -> (attribute name, value), so a variant's attribute rows can be
    # folded into a name/value map without joining back to the attribute table.
    values = {
        int(r["value_id"]): (attributes[int(r["attribute_id"])], r["value"])
        for r in read_csv(seed, "attribute_value")
    }
    return brands, categories, values


def category_document(category_id: int, categories: dict) -> dict:
    """Flatten the two-level tree into a leaf record carrying its breadcrumb.

    The breadcrumb is the denormalisation that removes a self-join from the
    product page: PostgreSQL resolves the parent category with a second join
    on category, the document already carries it.
    """
    leaf = categories[category_id]
    path = [leaf["name"]]
    parent_id = leaf["parent_id"]
    while parent_id is not None:
        parent = categories[parent_id]
        path.insert(0, parent["name"])
        parent_id = parent["parent_id"]
    return {
        "category_id": category_id,
        "name": leaf["name"],
        "slug": leaf["slug"],
        "path": path,
    }


def parse_created_at(text: str) -> datetime:
    return datetime.strptime(text, "%Y-%m-%d %H:%M:%S").replace(tzinfo=SEED_TIMEZONE)


def check_field_key(attribute: str) -> str:
    # Attribute names become BSON field names so that a filter reads like
    # variants.attributes.colour. BSON forbids '.' and '$' in field names, so
    # this is the one place the source data could break the model.
    if any(ch in attribute for ch in ".$") or not attribute:
        raise ValueError(f"attribute name cannot be used as a BSON field: {attribute!r}")
    return attribute


def build_documents(seed: Path) -> list[dict]:
    brands, categories, values = load_reference(seed)

    variants: dict[int, list[dict]] = {}
    for row in read_csv(seed, "product_variant"):
        product_id = int(row["product_id"])
        variants.setdefault(product_id, []).append(
            {
                "variant_id": int(row["variant_id"]),
                "sku": row["sku"],
                # Decimal128, not float: price is money and NUMERIC(12,2) on the
                # relational side. 0.1 + 0.2 is not 0.3 in binary floating point.
                "price": Decimal128(Decimal(row["price"])),
                "weight_g": int(row["weight_g"]) if row["weight_g"] else None,
                "status": row["status"],
                "attributes": {},
            }
        )

    variant_index = {
        v["variant_id"]: v for group in variants.values() for v in group
    }
    for row in read_csv(seed, "variant_attribute_value"):
        attribute, value = values[int(row["value_id"])]
        variant_index[int(row["variant_id"])]["attributes"][check_field_key(attribute)] = value

    categories_by_product: dict[int, list[int]] = {}
    for row in read_csv(seed, "product_category"):
        categories_by_product.setdefault(int(row["product_id"]), []).append(
            int(row["category_id"])
        )

    documents = []
    for row in read_csv(seed, "product"):
        product_id = int(row["product_id"])
        documents.append(
            {
                # The natural key doubles as _id: upserts are idempotent and the
                # join back to the relational schema needs no extra field.
                "_id": product_id,
                "name": row["name"],
                "description": row["description"],
                "status": row["status"],
                "created_at": parse_created_at(row["created_at"]),
                "brand": {"brand_id": int(row["brand_id"]), "name": brands[int(row["brand_id"])]},
                "categories": [
                    category_document(cid, categories)
                    for cid in sorted(categories_by_product.get(product_id, []))
                ],
                "variants": sorted(variants.get(product_id, []), key=lambda v: v["variant_id"]),
            }
        )
    return documents


def summarise(collection) -> None:
    stats = collection.database.command("collStats", collection.name, scale=1)
    total_variants = sum(
        doc["n"]
        for doc in collection.aggregate([{"$project": {"n": {"$size": "$variants"}}}])
    )
    print(f"documents        : {stats['count']:,}")
    print(f"embedded variants: {total_variants:,}")
    print(f"avg document size: {stats['avgObjSize']:.0f} bytes")
    print(f"collection size  : {stats['size'] / 1024 / 1024:.1f} MiB on disk (uncompressed)")
    print(f"indexes          : {len(list(collection.list_indexes()))} (only _id at this point)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uri", default="mongodb://127.0.0.1:27018/?directConnection=true")
    parser.add_argument("--db", default="shopstack")
    parser.add_argument("--collection", default="catalogue")
    parser.add_argument("--seed-dir", type=Path, default=DEFAULT_SEED)
    args = parser.parse_args()

    documents = build_documents(args.seed_dir)

    with MongoClient(args.uri, serverSelectionTimeoutMS=5000) as client:
        collection = client[args.db][args.collection]
        collection.drop()
        for start in range(0, len(documents), 1000):
            collection.insert_many(documents[start : start + 1000], ordered=False)
        summarise(collection)

    print(f"loaded {len(documents):,} products from {args.seed_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
