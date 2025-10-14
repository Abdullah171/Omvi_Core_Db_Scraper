#!/usr/bin/env python3
"""
Seed your Galaxy warehouse with JSON data.

Usage:
  python seed_insert.py --json seed_data.json
  # env overrides (optional): DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
"""

import argparse
import json
import os
import sys
from typing import List, Dict, Any, Tuple
import uuid
import psycopg
from psycopg import sql
from psycopg.types.json import Json

UUID_NS = uuid.uuid5(uuid.NAMESPACE_DNS, "omvi.local/seed")

DEFAULTS = {
    "DB_HOST": os.getenv("DB_HOST", "127.0.0.1"),
    "DB_PORT": int(os.getenv("DB_PORT", "5454")),   # from your .env / docker-compose
    "DB_NAME": os.getenv("DB_NAME", "galaxy"),
    "DB_USER": os.getenv("DB_USER", "galaxy"),
    "DB_PASSWORD": os.getenv("DB_PASSWORD", "galaxy"),
}




# Helper: split "schema.table" into (schema, table)
def _split_table(qualified: str) -> Tuple[str, str]:
    if "." in qualified:
        s, t = qualified.split(".", 1)
        return s, t
    return "public", qualified

def _get_column_types(conn, schema: str, table: str, cols: List[str]) -> Dict[str, str]:
    q = """
        SELECT column_name, data_type, udt_name
        FROM information_schema.columns
        WHERE table_schema = %s AND table_name = %s AND column_name = ANY(%s)
    """
    types = {}
    with conn.cursor() as cur:
        cur.execute(q, (schema, table, cols))
        for name, data_type, udt_name in cur.fetchall():
            # geometry shows up as USER-DEFINED + udt_name='geometry'
            types[name] = udt_name if data_type == 'USER-DEFINED' else data_type
    return types


def insert_rows(conn, qualified_table: str, cols: List[str], rows: List[Dict[str, Any]]):
    if not rows:
        return
    schema, table = _split_table(qualified_table)
    col_types = _get_column_types(conn, schema, table, cols)

    # Build VALUES and optional casts (we only need casts for special types)
    placeholders = []
    idents = [sql.Identifier(c) for c in cols]
    for c in cols:
        t = (col_types.get(c) or '').lower()
        if t in ('json', 'jsonb'):
            placeholders.append(sql.Placeholder())
        elif t == 'geometry':
            placeholders.append(sql.Placeholder())
        else:
            placeholders.append(sql.Placeholder())

    stmt = sql.SQL(
        "INSERT INTO {}.{} ({}) VALUES ({}) ON CONFLICT DO NOTHING"
    ).format(sql.Identifier(schema),
             sql.Identifier(table),
             sql.SQL(", ").join(idents),
             sql.SQL(", ").join(placeholders))

    def adapt_value(col: str, val: Any, col_types: Dict[str, str]):
        t = (col_types.get(col) or '').lower()
        if val is None:
            return None
        if t in ('json', 'jsonb'):
            if isinstance(val, (dict, list, int, float, bool)):
                return Json(val)
            if isinstance(val, str):
                try:
                    return Json(json.loads(val))
                except Exception:
                    return Json(val)
            return Json(val)
        if t == 'uuid':
            if isinstance(val, uuid.UUID):
                return str(val)
            if isinstance(val, str):
                try:
                    return str(uuid.UUID(val))
                except Exception:
                    return str(uuid.uuid5(UUID_NS, val))
            return str(uuid.uuid5(UUID_NS, str(val)))
        # geometry branch removed
        if t in ('double precision', 'numeric', 'real'):
            try:
                return float(val)
            except Exception:
                return None
        return val


    with conn.cursor() as cur:
        for r in rows:
            vals = [adapt_value(c, r.get(c), col_types) for c in cols]
            cur.execute(stmt, vals)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True, help="Path to seed_data.json")
    args = ap.parse_args()

    with open(args.json, "r", encoding="utf-8") as f:
        data = json.load(f)

    dsn = {
        "host": DEFAULTS["DB_HOST"],
        "port": DEFAULTS["DB_PORT"],
        "dbname": DEFAULTS["DB_NAME"],
        "user": DEFAULTS["DB_USER"],
        "password": DEFAULTS["DB_PASSWORD"],
    }

    print(f"Connecting to postgres://{dsn['user']}@{dsn['host']}:{dsn['port']}/{dsn['dbname']} ...")
    with psycopg.connect(**dsn) as conn:
        conn.autocommit = False

        try:
            # Seed order:
            # 1) hexes
            insert_rows(conn, "public.hexes", [
            "h3_id","resolution","country","country_alpha_3","country_alpha_2",
            # "geom",  <-- removed
            "lng","lat","h3_cell_area","status","name","boundary_type",
            "bearing_angle","bearing_label","state_alpha_2","state_fips",
            "pop_total_h5","housing_total_h5","housing_occupied_h5","pop_density_h5",
            "hex_estimated_value","hex_starting_bid","hex_current_bid","current_bid_token",
            "last_updated","number_of_bids","end_date","highest_bidder",
            "previous_highest_bidder","completion_date","number_of_agents",
            "number_of_watchers","next_bid"
        ], data.get("hexes", []))

            # 2) users, affiliate.users
            insert_rows(conn, "public.users", [
                "id","name","email","username","role","is_partner","email_verified","image",
                "display_username","billing_address","created_at"
            ], data.get("users", []))

            insert_rows(conn, "affiliate.users", [
                "id","name","email","username","role","is_partner","email_verified","image",
                "display_username","billing_address","created_at"
            ], data.get("affiliate_users", []))

            # 3) airnodes
            insert_rows(conn, "public.airnodes", [
                "id","type","purchase_status","initial_puchase_status","initial_purchase_status",
                "provisioning_status","host_id","operator_id","hardware_cells_ids","updated_at",
                "parent_id","version","name","batch_name","created_at","deleted_at"
            ], data.get("airnodes", []))

            # 4) nodehost
            insert_rows(conn, "public.nodehost", [
            "id","h3_id","host_name","host_email","agent_name","agent_email","building_id",
            "building_address","building_height_m","building_type",
            "lat","lng",  # replaced geom
            "building_floor_count"
        ], data.get("nodehost", []))


            # 5) sites
            insert_rows(conn, "public.sites", [
                "id","name","latitude","longitude","country","city","state","hexes","apex_lat","apex_lng"
            ], data.get("sites", []))

            # 6) sites_with_airnodes
            insert_rows(conn, "public.sites_with_airnodes", [
                "site_id","airnode_id"
            ], data.get("sites_with_airnodes", []))

            # 7) addresses
            insert_rows(conn, "public.addresses", [
                "id","created_at"
            ], data.get("addresses", []))

            # 8) host_locations
            insert_rows(conn, "public.host_locations", [
            "id","user_id","airnode_id","height","power_supply","hex_id","approved","listed",
            "longitude","latitude","zipcode","phone","property_phone","address_id",
            "equipment","instructions",
            # "geom",  <-- removed
            "created_at"
        ], data.get("host_locations", []))


            # 9) threads
            insert_rows(conn, "public.threads", [
                "id","host_location_id","host_id","operator_id","created_at"
            ], data.get("threads", []))

            # 10) operators
            insert_rows(conn, "public.operators", [
                "id","name","description","active","created_at"
            ], data.get("operators", []))

            # 11) payments (MOVED EARLIER to satisfy FK in airnode_inventory)
            insert_rows(conn, "public.payments", [
                "id","provider","provider_id","address_id","currency","total","paid","user_id",
                "is_expired","bank_transfer_url","bank_transfer_payment_intent_id",
                "bank_transfer_checkout_session_id","jira_order_id","freshdesk_id","node_ids",
                "created_at"
            ], data.get("payments", []))

            # 12) airnode_inventory (now with all fields)
            insert_rows(conn, "public.airnode_inventory", [
                "id","uuid","model","payment_id","is_reserved",
                "status_deposit_paid","status_purchased","status_shipped","status_delivered",
                "status_waiting_on_deployment","status_deployed","status_provisioning","status_active",
                "created_at"
            ], data.get("airnode_inventory", []))

            # 13) host_location_operator_map
            insert_rows(conn, "public.host_location_operator_map", [
                "id","host_location_id","operator_id","airnode_inventory_id","thread_id",
                "host_terms_accepted","operator_terms_accepted","contract_id",
                "world_mobile_terms_processed","created_at"
            ], data.get("host_location_operator_map", []))

            # 14) accounts
            insert_rows(conn, "public.accounts", [
                "id","type","provider","provider_account_id","refresh_token","access_token",
                "expires_at","token_type","scope","id_token","session_state","user_id",
                "access_token_expires_at","refresh_token_expires_at","password","created_at"
            ], data.get("accounts", []))

            # 15) admin_actions
            insert_rows(conn, "public.admin_actions", [
                "id","admin_id","user_id","user_email","action_status","created_at"
            ], data.get("admin_actions", []))

            # 16) cdr.earnings
            insert_rows(conn, "cdr.earnings", [
                "id","month_start","month_year_raw","node_id","node_type","affiliate_user_id",
                "operator_total","host_total","host_operator_total","created_at"
            ], data.get("cdr_earnings", []))

            # 17) cart.user_linked_affiliates
            insert_rows(conn, "cart.user_linked_affiliates", [
                "user_id","affiliate_code","created_at"
            ], data.get("user_linked_affiliates", []))

            conn.commit()
            print("✅ Seed completed.")
        except Exception as e:
            conn.rollback()
            print("❌ Error during seeding, rolled back:", e)
            sys.exit(1)


if __name__ == "__main__":
    main()



#docker compose run --rm   -e DB_HOST=db -e DB_PORT=5432 -e DB_NAME=galaxy -e DB_USER=galaxy -e DB_PASSWORD=galaxy   -v "$(pwd)/insert_data.py:/app/insert_data.py:ro"   -v "$(pwd)/data.json:/app/data.json:ro"   migrator python /app/insert_data.py --json /app/data.json