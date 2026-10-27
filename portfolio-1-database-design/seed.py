#!/usr/bin/env python3
"""
Deterministic seed data generator for the ShopStack case study.

Writes CSV files consumed by load.sql (COPY). Standard library only, so it runs
anywhere Python 3.9+ is available. The same SEED always produces identical data,
which matters because Portfolio 2 quotes execution plans and timings: the plans
must be reproducible against a fixed dataset.

Usage:
    python seed.py            # full volume (~10k products / 50k customers / 200k orders)
    python seed.py 0.1        # 10% scale, for quick iteration
    python seed.py 0.02       # smoke test

Output: ./seed-data/*.csv
"""

from __future__ import annotations

import csv
import random
import re
import sys
from contextlib import ExitStack
from datetime import datetime, timedelta
from pathlib import Path

SEED = 20261027
SCALE = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0
OUT = Path(__file__).resolve().parent / "seed-data"

START = datetime(2024, 10, 1)
END = datetime(2026, 10, 20)

rng = random.Random(SEED)


def n(base: int) -> int:
    return max(1, int(base * SCALE))


N_PRODUCTS = n(10_000)
N_CUSTOMERS = n(50_000)
N_ORDERS = n(200_000)
N_CARTS = n(5_000)
N_REVIEWS = n(80_000)
N_RETURNS = n(20_000)
N_WAREHOUSES = 4


# --------------------------------------------------------------------------- #
# Reference data
# --------------------------------------------------------------------------- #

BRANDS = [
    "Northwind", "Lumina", "Cobalt", "Verdant", "Atlas & Co", "Kestrel", "Meridian",
    "Halcyon", "Ferro", "Tidewater", "Basalt", "Quill", "Solace", "Nomad", "Ember",
    "Cinder", "Pallas", "Vantage", "Onyx", "Arbor", "Sable", "Kite", "Loom", "Pique",
    "Fathom", "Compass", "Drift", "Hollow", "Ivory", "Junction", "Kiln", "Larch",
    "Mosaic", "Nimbus", "Opal", "Parable", "Quarry", "Ridgeway", "Sundial", "Thistle",
]

CATEGORY_TREE = {
    "Electronics": ["Phones", "Laptops", "Audio", "Cameras"],
    "Fashion": ["Menswear", "Womenswear", "Footwear", "Accessories"],
    "Home & Kitchen": ["Cookware", "Furniture", "Bedding", "Small Appliances"],
    "Sports & Outdoors": ["Running", "Cycling", "Camping", "Gym"],
    "Books": ["Fiction", "Non-fiction", "Children", "Reference"],
    "Beauty": ["Skincare", "Haircare", "Fragrance", "Makeup"],
    "Toys & Games": ["Board Games", "Outdoor Play", "Puzzles", "Models"],
    "Grocery": ["Coffee", "Snacks", "Pantry", "Drinks"],
}

NOUNS = {
    "Electronics": ["Headphones", "Smartphone", "Laptop", "Speaker", "Camera", "Tablet", "Monitor", "Earbuds"],
    "Fashion": ["Jacket", "Shirt", "Trousers", "Dress", "Sneakers", "Boots", "Scarf", "Jumper"],
    "Home & Kitchen": ["Saucepan", "Lamp", "Duvet", "Blender", "Chair", "Mug", "Kettle", "Shelf"],
    "Sports & Outdoors": ["Trainers", "Bike", "Tent", "Dumbbell", "Backpack", "Yoga Mat", "Bottle", "Racket"],
    "Books": ["Novel", "Anthology", "Handbook", "Atlas", "Memoir", "Guidebook", "Almanac", "Primer"],
    "Beauty": ["Serum", "Shampoo", "Perfume", "Lipstick", "Cleanser", "Moisturiser", "Balm", "Mascara"],
    "Toys & Games": ["Puzzle", "Board Game", "Figure", "Kit", "Playset", "Cards", "Blocks", "Model"],
    "Grocery": ["Coffee Beans", "Biscuits", "Olive Oil", "Tea", "Chocolate", "Granola", "Pasta", "Juice"],
}

ADJECTIVES = [
    "Classic", "Premium", "Everyday", "Compact", "Ultra", "Heritage", "Studio", "Trail",
    "Alpine", "Coastal", "Nocturne", "Aero", "Essential", "Signature", "Vintage",
]

COLOURS = ["Black", "White", "Navy", "Grey", "Red", "Blue", "Green", "Beige", "Burgundy", "Olive"]
SIZES = ["XS", "S", "M", "L", "XL", "XXL"]
CAPACITIES = ["64GB", "128GB", "256GB", "512GB", "1TB"]

FIRST_NAMES = [
    "Amara", "Ben", "Chloe", "Damien", "Ebony", "Farid", "Grace", "Hassan", "Isla", "Jonas",
    "Keira", "Liam", "Maya", "Nadia", "Oscar", "Priya", "Quinn", "Rosa", "Samuel", "Tara",
    "Umar", "Vera", "Wesley", "Ximena", "Yusuf", "Zara", "Alistair", "Bianca", "Callum", "Dalia",
]

LAST_NAMES = [
    "Adeyemi", "Brennan", "Costa", "Duarte", "Ellis", "Fischer", "Gomez", "Hassan", "Ibrahim",
    "Jensen", "Kaur", "Larsen", "Mensah", "Novak", "Okafor", "Petrov", "Quinn", "Rahman",
    "Silva", "Turner", "Ueda", "Vasquez", "Whitfield", "Xu", "Yilmaz", "Zimmer", "Achterberg",
    "Boateng", "Chen", "Diallo",
]

# city, country, region, postcode prefix
CITIES = [
    ("London", "GB", "UK-South", "EC1A"),
    ("Manchester", "GB", "UK-North", "M1"),
    ("Leeds", "GB", "UK-North", "LS1"),
    ("Birmingham", "GB", "UK-Midlands", "B1"),
    ("Bristol", "GB", "UK-South", "BS1"),
    ("Edinburgh", "GB", "UK-Scotland", "EH1"),
    ("Berlin", "DE", "EU", "10115"),
    ("Munich", "DE", "EU", "80331"),
    ("Paris", "FR", "EU", "75001"),
    ("Lyon", "FR", "EU", "69001"),
    ("Newark", "US", "US-East", "07102"),
    ("Austin", "US", "US-South", "73301"),
    ("Seattle", "US", "US-West", "98101"),
]

ROADS = [
    "High Street", "Station Road", "Church Lane", "Victoria Road", "Mill Lane",
    "Queensway", "Park Avenue", "Kings Road", "Albert Street", "Marina Drive",
]

WAREHOUSES = [
    (1, "Northern DC", "Manchester", "GB", "UK-North"),
    (2, "Southern DC", "London", "GB", "UK-South"),
    (3, "EU Central DC", "Berlin", "DE", "EU"),
    (4, "US East DC", "Newark", "US", "US-East"),
]

CARRIERS = ["Royal Mail", "DPD", "DHL", "UPS", "Evri"]
PAYMENT_PROVIDERS = [("Stripe", "card"), ("PayPal", "wallet"), ("Adyen", "card"), ("Klarna", "bnpl")]
RETURN_REASONS = ["wrong item", "damaged", "not as described", "changed mind", "late delivery"]
REVIEW_TITLES = ["Exactly as described", "Good value", "Would buy again", "Not for me",
                 "Better than expected", "Arrived damaged", "Solid build", "Does the job"]
REVIEW_BODIES = ["Arrived quickly and matches the listing.", "Quality is fine for the price.",
                 "Packaging could be better but the item is good.", "Second one I have bought.",
                 "Size runs slightly small.", "Works as intended, no complaints."]

CURRENCY_BY_COUNTRY = {"GB": "GBP", "DE": "EUR", "FR": "EUR", "US": "USD"}
TAX_BY_COUNTRY = {"GB": 0.20, "DE": 0.19, "FR": 0.20, "US": 0.0}


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

def wchoice(pairs):
    total = sum(weight for _, weight in pairs)
    x = rng.uniform(0.0, total)
    acc = 0.0
    for value, weight in pairs:
        acc += weight
        if x <= acc:
            return value
    return pairs[-1][0]


def slugify(text: str) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", text.lower())).strip("-")


def rand_dt(start: datetime = START, end: datetime = END) -> datetime:
    span = max(1, int((end - start).total_seconds()))
    return start + timedelta(seconds=rng.randrange(span))


def dt_str(value: datetime | None) -> str:
    return "" if value is None else value.strftime("%Y-%m-%d %H:%M:%S")


def money(cents: int) -> str:
    """Format an integer number of minor units as a 2dp currency string."""
    return f"{cents // 100}.{cents % 100:02d}"


def clamp(value: datetime, ceiling: datetime = END) -> datetime:
    return value if value <= ceiling else ceiling


# --------------------------------------------------------------------------- #
# Generation
# --------------------------------------------------------------------------- #

def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    print(
        f"scale={SCALE}  products={N_PRODUCTS}  customers={N_CUSTOMERS}  orders={N_ORDERS}",
        file=sys.stderr,
    )

    with ExitStack() as stack:
        def w(name: str, header: list[str]):
            handle = stack.enter_context(
                open(OUT / f"{name}.csv", "w", newline="", encoding="utf-8")
            )
            writer = csv.writer(handle)
            writer.writerow(header)
            return writer

        # -- brand -----------------------------------------------------------
        w_brand = w("brand", ["brand_id", "name"])
        for brand_id, name in enumerate(BRANDS, start=1):
            w_brand.writerow([brand_id, name])

        # -- category (self-referencing hierarchy) ----------------------------
        w_cat = w("category", ["category_id", "parent_category_id", "name", "slug"])
        leaf_pool = []          # (root_name, category_id)
        category_id = 0
        for root_name, children in CATEGORY_TREE.items():
            category_id += 1
            root_id = category_id
            w_cat.writerow([root_id, "", root_name, slugify(root_name)])
            for child in children:
                category_id += 1
                w_cat.writerow([category_id, root_id, child, slugify(f"{root_name} {child}")])
                leaf_pool.append((root_name, category_id))

        # -- supplier --------------------------------------------------------
        w_supplier = w("supplier", ["supplier_id", "name", "country"])
        suppliers = []
        for supplier_id in range(1, 61):
            city, country, _, _ = CITIES[(supplier_id - 1) % len(CITIES)]
            suffix = ["Logistics", "Distribution", "Trading", "Supply"][supplier_id % 4]
            w_supplier.writerow([supplier_id, f"{city} {suffix} {supplier_id:02d}", country])
            suppliers.append(supplier_id)

        # -- attribute / attribute_value -------------------------------------
        w_attr = w("attribute", ["attribute_id", "name"])
        w_attr_val = w("attribute_value", ["value_id", "attribute_id", "value"])
        value_ids: dict[tuple[int, str], int] = {}
        next_value_id = 0
        attr_specs = [(1, "colour", COLOURS), (2, "size", SIZES), (3, "capacity", CAPACITIES)]
        for attr_id, attr_name, values in attr_specs:
            w_attr.writerow([attr_id, attr_name])
            for value in values:
                next_value_id += 1
                w_attr_val.writerow([next_value_id, attr_id, value])
                value_ids[(attr_id, value)] = next_value_id

        # -- product ---------------------------------------------------------
        w_prod = w("product", ["product_id", "name", "description", "brand_id", "status", "created_at"])
        w_prod_cat = w("product_category", ["product_id", "category_id"])
        w_prod_sup = w("product_supplier",
                       ["product_id", "supplier_id", "unit_cost", "lead_time_days", "is_primary"])

        product_root: dict[int, str] = {}
        product_base_price: dict[int, int] = {}
        leaves_by_root: dict[str, list[int]] = {}
        for root_name, leaf_id in leaf_pool:
            leaves_by_root.setdefault(root_name, []).append(leaf_id)

        for product_id in range(1, N_PRODUCTS + 1):
            root_name, leaf_id = leaf_pool[rng.randrange(len(leaf_pool))]
            brand_id = rng.randint(1, len(BRANDS))
            brand_name = BRANDS[brand_id - 1]
            noun = rng.choice(NOUNS[root_name])
            adjective = rng.choice(ADJECTIVES)
            base_cents = int(round((rng.uniform(4.0, 850.0) ** 1.02) * 100))

            w_prod.writerow([
                product_id,
                f"{brand_name} {adjective} {noun}",
                f"{adjective} {noun.lower()} from {brand_name}. {root_name} range.",
                brand_id,
                wchoice([("active", 95), ("discontinued", 5)]),
                dt_str(rand_dt(datetime(2023, 1, 1), END)),
            ])
            product_root[product_id] = root_name
            product_base_price[product_id] = base_cents

            w_prod_cat.writerow([product_id, leaf_id])
            if rng.random() < 0.10:
                others = [c for c in leaves_by_root[root_name] if c != leaf_id]
                if others:
                    w_prod_cat.writerow([product_id, rng.choice(others)])

            primary_supplier = rng.choice(suppliers)
            w_prod_sup.writerow([
                product_id, primary_supplier,
                money(int(round(base_cents * rng.uniform(0.45, 0.75)))),
                rng.randint(3, 45), "true",
            ])
            if rng.random() < 0.25:
                second = rng.choice([s for s in suppliers if s != primary_supplier])
                w_prod_sup.writerow([
                    product_id, second,
                    money(int(round(base_cents * rng.uniform(0.45, 0.80)))),
                    rng.randint(7, 70), "false",
                ])

        # -- product_variant / variant_attribute_value -----------------------
        w_var = w("product_variant",
                  ["variant_id", "product_id", "sku", "price", "weight_g", "status"])
        w_vav = w("variant_attribute_value", ["variant_id", "value_id"])

        variant_ids: list[int] = []
        variant_price: dict[int, int] = {}
        variant_product: dict[int, int] = {}
        variant_ids_by_product: dict[int, list[int]] = {}

        variant_id = 0
        price_factors = [0.85, 1.00, 1.15, 1.30]
        variant_count_weights = [(1, 25), (2, 45), (3, 20), (4, 10)]
        for product_id in range(1, N_PRODUCTS + 1):
            count = wchoice(variant_count_weights)
            base_cents = product_base_price[product_id]
            root_name = product_root[product_id]
            for index in range(count):
                variant_id += 1
                factor = price_factors[index] if count > 1 else 1.0
                price_cents = int(round(base_cents * factor))
                w_var.writerow([
                    variant_id, product_id, f"SKU-{product_id:05d}-{index + 1}",
                    money(price_cents), rng.randint(150, 4000),
                    "active" if rng.random() < 0.95 else "discontinued",
                ])
                variant_ids.append(variant_id)
                variant_price[variant_id] = price_cents
                variant_product[variant_id] = product_id
                variant_ids_by_product.setdefault(product_id, []).append(variant_id)

                w_vav.writerow([variant_id, value_ids[(1, rng.choice(COLOURS))]])
                if root_name == "Electronics":
                    w_vav.writerow([variant_id, value_ids[(3, rng.choice(CAPACITIES))]])
                else:
                    w_vav.writerow([variant_id, value_ids[(2, rng.choice(SIZES))]])

        # -- warehouse -------------------------------------------------------
        w_wh = w("warehouse", ["warehouse_id", "name", "city", "country", "region"])
        for row in WAREHOUSES:
            w_wh.writerow(list(row))

        # -- customer / customer_address -------------------------------------
        w_cust = w("customer",
                   ["customer_id", "email", "first_name", "last_name", "phone", "status", "created_at"])
        w_addr = w("customer_address",
                   ["address_id", "customer_id", "line1", "line2", "city", "region",
                    "postcode", "country", "is_default"])

        cust_addresses: dict[int, list[int]] = {}
        address_country: dict[int, str] = {}
        customer_country: dict[int, str] = {}
        address_id = 0

        for customer_id in range(1, N_CUSTOMERS + 1):
            first_name = rng.choice(FIRST_NAMES)
            last_name = rng.choice(LAST_NAMES)
            w_cust.writerow([
                customer_id,
                f"user{customer_id:06d}@example.com",
                first_name, last_name,
                f"+44{rng.randint(1000000000, 9999999999)}",
                wchoice([("active", 93), ("suspended", 4), ("closed", 3)]),
                dt_str(rand_dt(datetime(2022, 1, 1), datetime(2026, 6, 1))),
            ])

            ids = []
            for index in range(wchoice([(1, 70), (2, 30)])):
                address_id += 1
                city, country, region, prefix = rng.choice(CITIES)
                w_addr.writerow([
                    address_id, customer_id,
                    f"{rng.randint(1, 200)} {rng.choice(ROADS)}",
                    "", city, region,
                    f"{prefix} {rng.randint(1, 9)}{rng.choice('ABDEFGH')}{rng.choice('ABDEFGH')}",
                    country, "true" if index == 0 else "false",
                ])
                ids.append(address_id)
                address_country[address_id] = country
            cust_addresses[customer_id] = ids
            customer_country[customer_id] = address_country[ids[0]]

        # -- cart / cart_item ------------------------------------------------
        w_cart = w("cart", ["cart_id", "customer_id", "created_at", "status"])
        w_cart_item = w("cart_item", ["cart_id", "variant_id", "quantity"])
        for cart_id in range(1, N_CARTS + 1):
            w_cart.writerow([
                cart_id,
                rng.randint(1, N_CUSTOMERS),
                dt_str(rand_dt(END - timedelta(days=60), END)),
                wchoice([("open", 45), ("abandoned", 40), ("converted", 15)]),
            ])
            for variant in rng.sample(variant_ids, min(rng.randint(1, 4), len(variant_ids))):
                w_cart_item.writerow([cart_id, variant, rng.randint(1, 3)])

        # -- promotion -------------------------------------------------------
        w_promo = w("promotion", ["promotion_id", "code", "description", "discount_type",
                                  "discount_value", "min_spend", "starts_at", "ends_at"])
        promotions = []          # (promotion_id, type, value, min_spend_cents, starts, ends)
        promo_words = ["SAVE", "WELCOME", "SPRING", "AUTUMN", "FLASH", "LOYAL", "BULK", "CLEAR"]
        for promotion_id in range(1, 41):
            discount_type = wchoice([("percent", 75), ("fixed", 25)])
            if discount_type == "percent":
                discount_value = float(rng.choice([5, 10, 15, 20, 25]))   # percentage points
                value_field = f"{discount_value:.2f}"
                label = f"{int(discount_value)}% off"
            else:
                value_cents = rng.choice([5, 10, 15, 20, 25, 40, 50]) * 100
                discount_value = float(value_cents)
                value_field = money(value_cents)
                label = f"{value_cents // 100} off"
            min_spend_cents = rng.choice([0, 2500, 5000, 7500, 10000])
            starts = rand_dt(START, END - timedelta(days=30))
            ends = starts + timedelta(days=rng.randint(14, 120))
            code = f"{promo_words[promotion_id % len(promo_words)]}{promotion_id:02d}"
            w_promo.writerow([
                promotion_id, code, label,
                discount_type, value_field, money(min_spend_cents),
                dt_str(starts), dt_str(ends),
            ])
            promotions.append((promotion_id, discount_type, discount_value, min_spend_cents, starts, ends))

        # -- stock: initial restock movements + balances ---------------------
        w_movement = w("stock_movement", ["movement_id", "variant_id", "warehouse_id",
                                          "delta", "reason", "ref_order_id", "created_at"])
        movement_id = 0
        balance: dict[tuple[int, int], int] = {}
        variant_home: dict[int, int] = {}

        for variant in variant_ids:
            primary = rng.randint(1, N_WAREHOUSES)
            variant_home[variant] = primary
            warehouses = [primary]
            if rng.random() < 0.30:
                warehouses.append(rng.choice([x for x in range(1, N_WAREHOUSES + 1) if x != primary]))
            for warehouse in warehouses:
                quantity = rng.randint(600, 2400)
                balance[(variant, warehouse)] = quantity
                movement_id += 1
                created = START + timedelta(days=rng.randint(0, 10), seconds=rng.randrange(86400))
                w_movement.writerow([movement_id, variant, warehouse, quantity, "restock", "", dt_str(created)])

        # -- orders, lines, promotions, payments, shipments ------------------
        w_order = w("customer_order", ["order_id", "customer_id", "order_date", "status",
                                       "shipping_address_id", "billing_address_id", "currency",
                                       "subtotal", "discount_total", "shipping_total",
                                       "tax_total", "grand_total"])
        w_line = w("order_line", ["order_id", "variant_id", "quantity", "unit_price", "line_total"])
        w_op = w("order_promotion", ["order_id", "promotion_id", "discount_applied"])
        w_pay = w("payment", ["payment_id", "order_id", "provider", "method", "amount",
                              "status", "provider_ref", "created_at"])
        w_ship = w("shipment", ["shipment_id", "order_id", "carrier", "tracking_number",
                                "status", "dispatched_at", "delivered_at"])
        w_ship_line = w("shipment_line", ["shipment_id", "order_id", "variant_id", "quantity"])

        review_pool: list[tuple[int, int, datetime]] = []
        return_pool: list[tuple[int, int, int, float, datetime]] = []
        payment_id = 0
        shipment_id = 0

        order_dates = sorted(rand_dt() for _ in range(N_ORDERS))
        line_count_weights = [(1, 35), (2, 30), (3, 20), (4, 10), (5, 5)]
        quantity_weights = [(1, 70), (2, 22), (3, 8)]
        status_weights = [("delivered", 70), ("shipped", 8), ("paid", 7),
                          ("pending", 5), ("cancelled", 5), ("refunded", 5)]

        for order_id, order_date in enumerate(order_dates, start=1):
            customer_id = rng.randint(1, N_CUSTOMERS)
            addresses = cust_addresses[customer_id]
            shipping_address_id = rng.choice(addresses)
            billing_address_id = rng.choice(addresses)
            country = address_country[billing_address_id]
            currency = CURRENCY_BY_COUNTRY[country]
            tax_rate = TAX_BY_COUNTRY[country]

            line_count = min(wchoice(line_count_weights), len(variant_ids))
            picked = rng.sample(variant_ids, line_count)

            lines = []
            subtotal_cents = 0
            for variant in picked:
                quantity = wchoice(quantity_weights)
                unit_price_cents = int(round(variant_price[variant] * rng.uniform(0.88, 1.12)))
                line_total_cents = quantity * unit_price_cents
                subtotal_cents += line_total_cents
                lines.append((variant, quantity, unit_price_cents, line_total_cents))

            discount_cents = 0
            applied_promotion = None
            if rng.random() < 0.18:
                eligible = [p for p in promotions
                            if p[3] <= subtotal_cents and p[4] <= order_date <= p[5]]
                if eligible:
                    applied_promotion = rng.choice(eligible)
                    _, promo_type, promo_value, _, _, _ = applied_promotion
                    if promo_type == "percent":
                        discount_cents = int(round(subtotal_cents * promo_value / 100.0))
                    else:
                        discount_cents = min(int(promo_value), subtotal_cents // 2)

            shipping_cents = 0 if (subtotal_cents - discount_cents) >= 5000 else rng.choice([399, 499, 599])
            tax_cents = int(round((subtotal_cents - discount_cents) * tax_rate))
            grand_cents = subtotal_cents - discount_cents + shipping_cents + tax_cents
            status = wchoice(status_weights)

            w_order.writerow([
                order_id, customer_id, dt_str(order_date), status,
                shipping_address_id, billing_address_id, currency,
                money(subtotal_cents), money(discount_cents), money(shipping_cents),
                money(tax_cents), money(grand_cents),
            ])

            for variant, quantity, unit_price_cents, line_total_cents in lines:
                w_line.writerow([order_id, variant, quantity,
                                 money(unit_price_cents), money(line_total_cents)])

            if applied_promotion is not None:
                w_op.writerow([order_id, applied_promotion[0], money(discount_cents)])

            # Stock is only consumed by orders that actually shipped.
            if status in ("paid", "shipped", "delivered", "refunded"):
                for variant, quantity, _, _ in lines:
                    warehouse = variant_home[variant]
                    key = (variant, warehouse)
                    if balance[key] < quantity:
                        restock = rng.randint(800, 2000)
                        balance[key] += restock
                        movement_id += 1
                        w_movement.writerow([movement_id, variant, warehouse, restock,
                                             "restock", "", dt_str(order_date)])
                    balance[key] -= quantity
                    movement_id += 1
                    w_movement.writerow([movement_id, variant, warehouse, -quantity,
                                         "sale", order_id, dt_str(order_date)])

            # Payments: one attempt for settled orders, the occasional failure.
            if status in ("paid", "shipped", "delivered", "refunded") or (
                status == "cancelled" and rng.random() < 0.15
            ):
                payment_id += 1
                if status == "refunded":
                    payment_status = "refunded"
                elif status == "cancelled":
                    payment_status = "failed"
                else:
                    payment_status = "paid"
                provider, method = rng.choice(PAYMENT_PROVIDERS)
                created = order_date + timedelta(minutes=rng.randint(0, 120))
                w_pay.writerow([
                    payment_id, order_id, provider, method, money(grand_cents), payment_status,
                    f"{provider[:3].upper()}-{payment_id:09d}", dt_str(created),
                ])

            # Shipments, including the 10% of orders split across two parcels.
            if status in ("delivered", "shipped"):
                groups = [lines]
                if status == "delivered" and rng.random() < 0.10 and len(lines) > 1:
                    split = len(lines) // 2
                    groups = [lines[:split], lines[split:]]
                for group in groups:
                    if not group:
                        continue
                    shipment_id += 1
                    dispatched = order_date + timedelta(days=rng.randint(0, 3),
                                                        hours=rng.randint(1, 20))
                    if status == "delivered":
                        delivered = dispatched + timedelta(days=rng.randint(1, 6))
                        shipment_status = "delivered"
                    else:
                        delivered = None
                        shipment_status = wchoice([("dispatched", 60), ("in_transit", 40)])
                    w_ship.writerow([
                        shipment_id, order_id, rng.choice(CARRIERS),
                        f"TRK{shipment_id:011d}", shipment_status,
                        dt_str(dispatched), dt_str(delivered),
                    ])
                    for variant, quantity, _, _ in group:
                        w_ship_line.writerow([shipment_id, order_id, variant, quantity])

            if status == "delivered":
                for variant, quantity, unit_price_cents, _ in lines:
                    if rng.random() < 0.22:
                        review_pool.append((customer_id, variant_product[variant], order_date))
                    if rng.random() < 0.06:
                        return_pool.append((order_id, variant, quantity, unit_price_cents, order_date))

        # -- stock_level snapshot --------------------------------------------
        w_stock = w("stock_level", ["variant_id", "warehouse_id", "quantity",
                                    "reorder_point", "updated_at"])
        for (variant, warehouse), quantity in balance.items():
            w_stock.writerow([variant, warehouse, quantity, rng.randint(20, 100), dt_str(END)])

        # -- review ----------------------------------------------------------
        w_review = w("review", ["review_id", "customer_id", "product_id", "rating",
                                "title", "body", "created_at"])
        rng.shuffle(review_pool)
        seen_reviews: set[tuple[int, int]] = set()
        review_id = 0
        for customer_id, product_id, order_date in review_pool:
            if review_id >= N_REVIEWS:
                break
            key = (customer_id, product_id)
            if key in seen_reviews:
                continue
            seen_reviews.add(key)
            review_id += 1
            created = clamp(order_date + timedelta(days=rng.randint(1, 40)))
            w_review.writerow([
                review_id, customer_id, product_id,
                wchoice([(5, 45), (4, 30), (3, 15), (2, 6), (1, 4)]),
                rng.choice(REVIEW_TITLES), rng.choice(REVIEW_BODIES), dt_str(created),
            ])

        # -- return_request --------------------------------------------------
        w_return = w("return_request", ["return_id", "order_id", "variant_id", "quantity",
                                        "reason", "status", "refund_amount", "created_at"])
        rng.shuffle(return_pool)
        seen_returns: set[tuple[int, int]] = set()
        return_id = 0
        for order_id, variant, quantity, unit_price_cents, order_date in return_pool:
            if return_id >= N_RETURNS:
                break
            key = (order_id, variant)
            if key in seen_returns:
                continue
            seen_returns.add(key)
            return_id += 1
            returned_quantity = 1 if quantity == 1 else rng.randint(1, quantity)
            return_status = wchoice([("refunded", 55), ("received", 15), ("approved", 15),
                                     ("requested", 10), ("rejected", 5)])
            refund_cents = 0 if return_status in ("requested", "rejected") else (
                returned_quantity * unit_price_cents
            )
            w_return.writerow([
                return_id, order_id, variant, returned_quantity,
                rng.choice(RETURN_REASONS), return_status, money(refund_cents),
                dt_str(clamp(order_date + timedelta(days=rng.randint(2, 30)))),
            ])

    print(f"done -> {OUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
