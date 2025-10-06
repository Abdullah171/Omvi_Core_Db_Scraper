-- ===========================================================
-- Galaxy Warehouse Core Schema (PostgreSQL + PostGIS)
-- Consistent, idempotent, ready to extend.
-- ===========================================================

-- ---------- Extensions ----------
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS citext;
-- CREATE EXTENSION IF NOT EXISTS vector; -- enable later if/when you add embeddings

-- ---------- Schemas ----------
CREATE SCHEMA IF NOT EXISTS affiliate;
CREATE SCHEMA IF NOT EXISTS cdr;
CREATE SCHEMA IF NOT EXISTS cart;

-- ---------- Utility: updated_at trigger ----------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ===========================================================
-- Dimension: hexes (no deps)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.hexes (
  h3_id               text PRIMARY KEY,
  resolution          integer NOT NULL,
  country             varchar(64),
  country_alpha_3     varchar(8),
  country_alpha_2     varchar(8),
  geom                geometry(MultiPolygon, 4326),
  lng                 double precision,
  lat                 double precision,
  h3_cell_area        double precision,
  status              varchar(32),
  name                varchar(256),
  boundary_type       varchar(8),
  bearing_angle       double precision,
  bearing_label       varchar(8),
  state_alpha_2       varchar(8),
  state_fips          varchar(8),
  pop_total_h5        double precision,
  housing_total_h5    double precision,
  housing_occupied_h5 double precision,
  pop_density_h5      double precision,
  hex_estimated_value double precision,
  hex_starting_bid    double precision,
  hex_current_bid     double precision,
  current_bid_token   varchar(64)
);
CREATE INDEX IF NOT EXISTS idx_hexes_resolution ON public.hexes (resolution);
CREATE INDEX IF NOT EXISTS idx_hexes_geom_gix   ON public.hexes USING GIST (geom);

-- ===========================================================
-- Dimension: users (no deps)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.users (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  name              varchar(255),
  email             citext UNIQUE,
  username          citext,
  role              varchar(255),
  is_partner        boolean,
  email_verified    boolean,
  image             varchar(255),
  display_username  varchar(255),
  billing_address   varchar(255),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
DO $$
BEGIN
  CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ===========================================================
-- Dimension: airnodes (no deps)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.airnodes (
  id                       text PRIMARY KEY,
  type                     integer,              -- from uint
  purchase_status          integer,              -- from uint
  -- Source spec contains a typo; keep both for safety when ingesting:
  initial_puchase_status   integer,              -- typo kept for ingest
  initial_purchase_status  integer,              -- normalized name for future use
  provisioning_status      integer,              -- from uint
  host_id                  text,
  operator_id              text,
  hardware_cells_ids       jsonb,
  updated_at               timestamptz,
  parent_id                text,
  version                  integer,
  name                     text,
  batch_name               text,
  created_at               timestamptz DEFAULT now(),
  deleted_at               timestamptz
);

-- ===========================================================
-- Dimension: nodehost (deps: hexes)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.nodehost (
  id                    bigserial PRIMARY KEY,
  h3_id                 text REFERENCES public.hexes(h3_id) ON DELETE SET NULL,
  host_name             text,
  host_email            text,
  agent_name            text,
  agent_email           text,
  building_id           integer,        -- placeholder until buildings dim exists
  building_address      text,
  building_height_m     double precision,
  building_type         varchar(64),
  geom                  geometry(Point, 4326),
  building_floor_count  integer
);
CREATE INDEX IF NOT EXISTS idx_nodehost_h3_id    ON public.nodehost(h3_id);
CREATE INDEX IF NOT EXISTS idx_nodehost_geom_gix ON public.nodehost USING GIST (geom);

-- ===========================================================
-- Dimension: sites (no deps) + bridge (deps: airnodes)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.sites (
  id          text PRIMARY KEY,
  name        text,
  latitude    double precision,
  longitude   double precision,
  country     text,
  city        text,
  state       text,
  hexes       jsonb,
  apex_lat    double precision,
  apex_lng    double precision
);
CREATE INDEX IF NOT EXISTS idx_sites_country_city ON public.sites(country, city);

CREATE TABLE IF NOT EXISTS public.sites_with_airnodes (
  site_id     text REFERENCES public.sites(id)    ON DELETE CASCADE,
  airnode_id  text REFERENCES public.airnodes(id) ON DELETE CASCADE,
  PRIMARY KEY (site_id, airnode_id)
);

-- ===========================================================
-- Support/Lookup dimensions (no external deps)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.addresses (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  -- add address fields later as needed
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
DO $$
BEGIN
  CREATE TRIGGER trg_addresses_updated_at
  BEFORE UPDATE ON public.addresses
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS public.operators (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  name        text,
  description text,
  active      boolean,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
DO $$
BEGIN
  CREATE TRIGGER trg_operators_updated_at
  BEFORE UPDATE ON public.operators
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS public.airnode_inventory (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  -- add model/phase fields later as needed
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
DO $$
BEGIN
  CREATE TRIGGER trg_airnode_inventory_updated_at
  BEFORE UPDATE ON public.airnode_inventory
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ===========================================================
-- Dimension: host_locations (deps: users, airnodes, hexes, addresses)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.host_locations (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id           uuid REFERENCES public.users(id)        ON DELETE SET NULL,
  airnode_id        text REFERENCES public.airnodes(id)     ON DELETE SET NULL,
  height            varchar(255),
  power_supply      varchar(255),
  hex_id            text REFERENCES public.hexes(h3_id)     ON DELETE SET NULL,
  approved          boolean,
  listed            boolean,
  longitude         double precision,
  latitude          double precision,
  zipcode           varchar(255),
  phone             varchar(255),
  property_phone    varchar(255),
  address_id        uuid REFERENCES public.addresses(id)    ON DELETE SET NULL,
  equipment         varchar(255),
  instructions      varchar(255),
  geom              geometry(Point, 4326)
    GENERATED ALWAYS AS (
      CASE
        WHEN longitude IS NOT NULL AND latitude IS NOT NULL
        THEN ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)
        ELSE NULL
      END
    ) STORED,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
DO $$
BEGIN
  CREATE TRIGGER trg_host_locations_updated_at
  BEFORE UPDATE ON public.host_locations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS idx_host_locations_user   ON public.host_locations(user_id);
CREATE INDEX IF NOT EXISTS idx_host_locations_airnode ON public.host_locations(airnode_id);
CREATE INDEX IF NOT EXISTS idx_host_locations_hex    ON public.host_locations(hex_id);
CREATE INDEX IF NOT EXISTS idx_host_locations_geom   ON public.host_locations USING GIST (geom);

-- ===========================================================
-- Dimension: threads (deps: host_locations, users)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.threads (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  host_location_id  uuid REFERENCES public.host_locations(id) ON DELETE SET NULL,
  host_id           uuid REFERENCES public.users(id)          ON DELETE SET NULL,
  operator_id       uuid REFERENCES public.users(id)          ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
DO $$
BEGIN
  CREATE TRIGGER trg_threads_updated_at
  BEFORE UPDATE ON public.threads
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS idx_threads_hl ON public.threads(host_location_id);

-- ===========================================================
-- Bridge: host_location_operator_map
-- (deps: host_locations, operators, airnode_inventory, threads)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.host_location_operator_map (
  id                           uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  host_location_id             uuid REFERENCES public.host_locations(id)    ON DELETE CASCADE,
  operator_id                  uuid REFERENCES public.operators(id)         ON DELETE SET NULL,
  airnode_inventory_id         uuid REFERENCES public.airnode_inventory(id) ON DELETE SET NULL,
  thread_id                    uuid REFERENCES public.threads(id)           ON DELETE SET NULL,
  host_terms_accepted          timestamptz,
  operator_terms_accepted      timestamptz,
  contract_id                  varchar(255),
  world_mobile_terms_processed timestamptz,
  created_at                   timestamptz NOT NULL DEFAULT now(),
  updated_at                   timestamptz NOT NULL DEFAULT now()
);
DO $$
BEGIN
  CREATE TRIGGER trg_hlom_updated_at
  BEFORE UPDATE ON public.host_location_operator_map
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS idx_hlom_host_location ON public.host_location_operator_map(host_location_id);
CREATE INDEX IF NOT EXISTS idx_hlom_operator      ON public.host_location_operator_map(operator_id);

-- ===========================================================
-- Fact: payments (deps: addresses, users)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.payments (
  id                                uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider                          varchar(255),
  provider_id                       varchar(255),
  address_id                        uuid REFERENCES public.addresses(id) ON DELETE SET NULL,
  currency                          varchar(255),
  total                             bigint CHECK (total >= 0),
  paid                              bigint CHECK (paid  >= 0),
  user_id                           uuid REFERENCES public.users(id)     ON DELETE SET NULL,
  is_expired                        boolean,
  bank_transfer_url                 text,
  bank_transfer_payment_intent_id   text,
  bank_transfer_checkout_session_id text,
  jira_order_id                     text,
  freshdesk_id                      text,
  node_ids                          text,
  created_at                        timestamptz NOT NULL DEFAULT now(),
  updated_at                        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_paid_le_total CHECK (paid <= total)
);
DO $$
BEGIN
  CREATE TRIGGER trg_payments_updated_at
  BEFORE UPDATE ON public.payments
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS idx_payments_user       ON public.payments(user_id);
CREATE INDEX IF NOT EXISTS idx_payments_created_at ON public.payments(created_at);
CREATE INDEX IF NOT EXISTS idx_payments_provider   ON public.payments(provider, provider_id);

-- ===========================================================
-- Dimension: accounts (deps: users)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.accounts (
  id                       uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  type                     varchar(255),
  provider                 varchar(255),
  provider_account_id      varchar(255),
  refresh_token            varchar(255),
  access_token             varchar(255),
  expires_at               bigint,
  token_type               varchar(255),
  scope                    varchar(255),
  id_token                 text,
  session_state            varchar(255),
  user_id                  uuid REFERENCES public.users(id) ON DELETE CASCADE,
  access_token_expires_at  timestamptz,
  refresh_token_expires_at timestamptz,
  password                 varchar(255),
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now()
);
DO $$
BEGIN
  CREATE TRIGGER trg_accounts_updated_at
  BEFORE UPDATE ON public.accounts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS idx_accounts_user ON public.accounts(user_id);

-- ===========================================================
-- Log/Fact: admin_actions (deps: users)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.admin_actions (
  id            bigserial PRIMARY KEY,
  admin_id      uuid,
  user_id       uuid REFERENCES public.users(id) ON DELETE SET NULL,
  user_email    varchar(254),
  action_status varchar(20),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_admin_actions_user       ON public.admin_actions(user_id);
CREATE INDEX IF NOT EXISTS idx_admin_actions_created_at ON public.admin_actions(created_at);

-- ===========================================================
-- affiliate.users (no external deps)
-- ===========================================================
CREATE TABLE IF NOT EXISTS affiliate.users (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  name              varchar(255),
  email             citext UNIQUE,
  username          citext,
  role              varchar(255),
  is_partner        boolean,
  email_verified    boolean,
  image             varchar(255),
  display_username  varchar(255),
  billing_address   varchar(255),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
DO $$
BEGIN
  CREATE TRIGGER trg_affiliate_users_updated_at
  BEFORE UPDATE ON affiliate.users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ===========================================================
-- cdr.earnings (deps: airnodes, affiliate.users)
-- ===========================================================
CREATE TABLE IF NOT EXISTS cdr.earnings (
  id                   text PRIMARY KEY,              -- e.g., "earnings:<node_id>_<YYYY_MM>"
  month_start          date,                          -- first day of the month
  month_year_raw       text,                          -- optional raw value from source (e.g., "2025_09")
  node_id              text REFERENCES public.airnodes(id) ON DELETE SET NULL,
  node_type            text,
  affiliate_user_id    uuid REFERENCES affiliate.users(id) ON DELETE SET NULL,
  operator_total       bigint CHECK (operator_total >= 0),
  host_total           bigint CHECK (host_total >= 0),
  host_operator_total  bigint CHECK (host_operator_total >= 0),
  created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_cdr_earnings_node        ON cdr.earnings(node_id);
CREATE INDEX IF NOT EXISTS idx_cdr_earnings_month_start ON cdr.earnings(month_start);

-- ===========================================================
-- cart.user_linked_affiliates (deps: users)
-- ===========================================================
CREATE TABLE IF NOT EXISTS cart.user_linked_affiliates (
  user_id        uuid REFERENCES public.users(id) ON DELETE CASCADE,
  affiliate_code text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  PRIMARY KEY (user_id, affiliate_code)
);
CREATE INDEX IF NOT EXISTS idx_ula_created_at ON cart.user_linked_affiliates(created_at);

-- ===========================================================
-- Helpful views (deps: hexes, host_locations)
-- ===========================================================
CREATE OR REPLACE VIEW public.v_airnodes_per_hex AS
SELECT h.h3_id, COUNT(DISTINCT hl.airnode_id) AS airnodes_count
FROM public.hexes h
LEFT JOIN public.host_locations hl ON hl.hex_id = h.h3_id
GROUP BY h.h3_id;

-- ===========================================================
-- Seed order hint (comment only)
-- 1) hexes
-- 2) users, affiliate.users
-- 3) airnodes
-- 4) nodehost
-- 5) sites
-- 6) addresses
-- 7) host_locations
-- 8) threads
-- 9) operators, airnode_inventory
-- 10) host_location_operator_map
-- 11) payments
-- 12) accounts
-- 13) admin_actions
-- 14) cdr.earnings
-- 15) cart.user_linked_affiliates
-- 16) views
-- ===========================================================
