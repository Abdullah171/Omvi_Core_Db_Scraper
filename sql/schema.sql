-- ===========================================================
-- Galaxy Warehouse Core Schema (PostgreSQL + PostGIS)
-- Consistent, idempotent, ready to extend.
-- ===========================================================

-- ---------- Extensions ----------
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

-- =========================
-- Dimension: hexes (no PostGIS)
-- =========================
CREATE TABLE IF NOT EXISTS public.hexes (
  h3_id                   text PRIMARY KEY,
  resolution              integer NOT NULL,
  country                 varchar(64),
  country_alpha_3         varchar(8),
  country_alpha_2         varchar(8),
  -- geom removed
  lng                     double precision,
  lat                     double precision,
  h3_cell_area            double precision,
  status                  varchar(32),
  name                    varchar(256),
  boundary_type           varchar(8),
  bearing_angle           double precision,
  bearing_label           varchar(8),
  state_alpha_2           varchar(8),
  state_fips              varchar(8),
  pop_total_h5            double precision,
  housing_total_h5        double precision,
  housing_occupied_h5     double precision,
  pop_density_h5          double precision,
  hex_estimated_value     double precision,
  hex_starting_bid        double precision,
  hex_current_bid         double precision,
  current_bid_token       varchar(64),
  last_updated            timestamptz,
  number_of_bids          integer,
  end_date                timestamptz,
  highest_bidder          varchar(64),
  previous_highest_bidder varchar(64),
  completion_date         timestamptz,
  number_of_agents        integer,
  number_of_watchers      integer,
  next_bid                varchar(64)
);

CREATE INDEX IF NOT EXISTS idx_hexes_resolution   ON public.hexes (resolution);
-- dropped: idx_hexes_geom_gix
CREATE INDEX IF NOT EXISTS idx_hexes_country_city ON public.hexes (country, country_alpha_2);
CREATE INDEX IF NOT EXISTS idx_hexes_status       ON public.hexes (status);

-- =========================
-- Dimension: nodehost (no PostGIS) — #1 occurrence
-- =========================
CREATE TABLE IF NOT EXISTS public.nodehost (
  id                    bigserial PRIMARY KEY,
  h3_id                 text REFERENCES public.hexes(h3_id) ON DELETE SET NULL,
  host_name             text,
  host_email            text,
  agent_name            text,
  agent_email           text,
  building_id           integer,
  building_address      text,
  building_height_m     double precision,
  building_type         varchar(64),
  -- geom replaced with lat/lng
  lat                   double precision,
  lng                   double precision,
  building_floor_count  integer
);

CREATE INDEX IF NOT EXISTS idx_nodehost_h3_id ON public.nodehost(h3_id);
-- dropped: idx_nodehost_geom_gix

-- ===========================================================
-- Dimension: users (no deps)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.users (
  -- keys & identity
  id                 uuid PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- core profile (both CSV variants merged)
  name               varchar(255),
  email              citext UNIQUE,
  username           citext,
  role               varchar(255),
  status             varchar(20),

  -- booleans
  is_partner         boolean,
  email_verified     boolean,

  -- display & billing
  image              varchar(255),
  display_username   varchar(255),
  billing_address    varchar(255),

  -- community / marketing fields (CSV row 7)
  x                  varchar(100),
  discord            varchar(100),
  about              text,
  code               varchar(20),
  referrals          int,

  -- package interest/tiers (CSV row 7)
  global_1           int,
  global_6           int,
  global_12          int,
  essential_1        int,
  essential_6        int,
  essential_12       int,
  advanced_1         int,
  advanced_6         int,
  advanced_12        int,

  -- discounts (CSV row 7)
  discount_type      public.discount_type_enum,

  -- timestamps
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Helpful indexes (optional)
CREATE INDEX IF NOT EXISTS idx_users_role        ON public.users(role);
CREATE INDEX IF NOT EXISTS idx_users_created_at  ON public.users(created_at);

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
-- Support/Lookup dimensions (no external deps)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.addresses (
  id           uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  line1        varchar(255),
  line2        varchar(255),
  city         varchar(255),
  state        varchar(255),
  postal_code  varchar(255),
  country      varchar(255),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  CREATE TRIGGER trg_addresses_updated_at
  BEFORE UPDATE ON public.addresses
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Optional index for common lookups
CREATE INDEX IF NOT EXISTS idx_addresses_city_state ON public.addresses(city, state);



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

-- =========================
-- Dimension: host_locations (deps: users, airnodes, hexes, addresses)
-- =========================
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
  -- geom computed column removed
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

CREATE INDEX IF NOT EXISTS idx_host_locations_user    ON public.host_locations(user_id);
CREATE INDEX IF NOT EXISTS idx_host_locations_airnode ON public.host_locations(airnode_id);
CREATE INDEX IF NOT EXISTS idx_host_locations_hex     ON public.host_locations(hex_id);
-- dropped: idx_host_locations_geom

-- ===========================================================
-- Dimension: threads (deps: host_locations, users)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.threads (
  id                      uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  host_location_id        uuid REFERENCES public.host_locations(id) ON DELETE SET NULL,
  host_id                 uuid REFERENCES public.users(id)          ON DELETE SET NULL,
  operator_id             uuid REFERENCES public.users(id)          ON DELETE SET NULL,

  -- CSV-missing in your script; now included:
  last_message_time       timestamptz,
  is_archived_by_host     boolean,
  is_archived_by_operator boolean,

  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  CREATE TRIGGER trg_threads_updated_at
  BEFORE UPDATE ON public.threads
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Helpful index
CREATE INDEX IF NOT EXISTS idx_threads_host_location ON public.threads(host_location_id);


-- ===========================================================
-- Dimension: airnode_inventory (deps: payments)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.airnode_inventory (
  id                            uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  uuid                          varchar(255),  -- from screenshot (string(255))
  model                         varchar(255),
  payment_id                    uuid REFERENCES public.payments(id) ON DELETE SET NULL,
  is_reserved                   boolean,
  status_deposit_paid           timestamptz(6),
  status_purchased              timestamptz(6),
  status_shipped                timestamptz(6),
  status_delivered              timestamptz(6),
  status_waiting_on_deployment  timestamptz(6),
  status_deployed               timestamptz(6),
  status_provisioning           timestamptz(6),
  status_active                 timestamptz(6),
  created_at                    timestamptz NOT NULL DEFAULT now(),
  updated_at                    timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  CREATE TRIGGER trg_airnode_inventory_updated_at
  BEFORE UPDATE ON public.airnode_inventory
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS idx_airnode_inventory_payment_id
  ON public.airnode_inventory(payment_id);

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


CREATE SCHEMA IF NOT EXISTS dcc;  -- to host the alternate "users" from CSV

-- ---------- Helper to guard trigger creation ----------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'set_updated_at'
  ) THEN
    CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
    BEGIN
      NEW.updated_at = now();
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
  END IF;
END $$;

-- ===========================================================
-- Engagement / Interest
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.hex_interest (
  hex_id     text REFERENCES public.hexes(h3_id) ON DELETE CASCADE,
  user_id    uuid REFERENCES public.users(id)    ON DELETE CASCADE,
  created_at timestamptz,
  updated_at timestamptz,
  PRIMARY KEY (hex_id, user_id)
);

-- (Already created earlier) public.sites_with_airnodes

-- ===========================================================
-- Catalogue-like tables
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.partners (
  id         uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  name       varchar(255),
  created_at timestamptz,
  updated_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.hexagons (
  id          varchar(255) PRIMARY KEY,
  is_neighbour boolean,
  partner_id  uuid REFERENCES public.partners(id) ON DELETE SET NULL,
  spectrum    varchar(255),
  created_at  timestamptz,
  updated_at  timestamptz
);

-- ===========================================================
-- Stake & Payouts
-- ===========================================================
CREATE TYPE public.stake_action_type AS ENUM ('stake','unstake','increase','decrease');

CREATE TABLE IF NOT EXISTS public.stake (
  id                 uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  transaction_id     varchar,
  contact_address    varchar,
  wallet_address     varchar,
  stake_tier         int,
  type               public.stake_action_type,
  amount             bigint,
  transaction_amount bigint,
  user_id            uuid REFERENCES public.users(id) ON DELETE SET NULL,
  updated_at         timestamptz,
  created_at         timestamptz
);

-- Ledger "account" (distinct from auth "accounts")
CREATE TABLE IF NOT EXISTS public.account (
  id         uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    uuid REFERENCES public.users(id) ON DELETE SET NULL,
  name       text,
  type       text,
  details    jsonb,
  is_locked  boolean,
  is_default boolean,
  is_active  boolean
);

CREATE TABLE IF NOT EXISTS public.payouts (
  id            uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id       uuid REFERENCES public.users(id) ON DELETE SET NULL,
  amount        int,
  month         varchar,
  claimed       boolean,
  paid          boolean,
  paid_at       timestamptz,
  -- CSV has a typo "acoount_id"; we keep it to preserve source, and link it:
  acoount_id    uuid REFERENCES public.account(id) ON DELETE SET NULL,
  claimed_at    timestamptz,
  claim_currency varchar(255),
  bank_tx_id    varchar(255),
  is_manual     boolean
);

-- ===========================================================
-- Payments / Commerce domain
-- ===========================================================
CREATE TYPE public.payment_status AS ENUM ('created','pending','paid','failed','expired','refunded');

CREATE TYPE public.item_type AS ENUM (
  'airnode','deposit','final','sim','esim','addon','plan','number','other'
);

CREATE TYPE public.order_status AS ENUM (
  'created','awaiting_payment','paid','processing','fulfilled','cancelled','refunded'
);

CREATE TYPE public.sub_status AS ENUM (
  'active','past_due','canceled','incomplete','incomplete_expired','trialing','unpaid'
);

CREATE TABLE IF NOT EXISTS public.orders (
  id                          bigserial PRIMARY KEY,
  created_at                  timestamptz,
  updated_at                  timestamptz,
  deleted_at                  timestamptz,
  payment_type                varchar,
  payment_id                  uuid REFERENCES public.payments(id) ON DELETE SET NULL,
  user_id                     uuid REFERENCES public.users(id)    ON DELETE SET NULL,
  status                      public.order_status,
  coupon_code                 varchar,
  affiliate_id                varchar,
  affiliate_discount_amount   int,
  family_discount_amount      int,
  wm_coupon_code              varchar,
  wm_coupon_discount_amount   int,
  tier_staking_percent        double precision,
  tier_staking_discount       int
);

CREATE TABLE IF NOT EXISTS public.items (
  id             bigserial PRIMARY KEY,
  created_at     timestamptz,
  updated_at     timestamptz,
  deleted_at     timestamptz,
  product_type   public.item_type,
  product_id     varchar,
  order_id       bigint REFERENCES public.orders(id) ON DELETE CASCADE,
  reservation_id bigint,
  price          int,
  metadata       text
);

CREATE TABLE IF NOT EXISTS public.subscriptions (
  id                      bigserial PRIMARY KEY,
  created_at              timestamptz,
  updated_at              timestamptz,
  deleted_at              timestamptz,
  user_id                 uuid REFERENCES public.users(id) ON DELETE CASCADE,
  current_period_start    timestamptz,
  current_period_end      timestamptz,
  status                  public.sub_status,
  last_payment_id         uuid REFERENCES public.payments(id) ON DELETE SET NULL,
  last_payment_amount     int,
  product_id              varchar,
  product                 public.item_type,
  product_key             varchar,
  item_id                 bigint REFERENCES public.items(id) ON DELETE SET NULL,
  sub_period              varchar,
  affiliate_id            varchar,
  first_payment_discounted boolean,
  first_payment_discount_amount int,
  original_undiscounted_amount  int,
  family_discount_amount        int,
  payment_provider              varchar,
  provider_sub_id               varchar
);

CREATE TABLE IF NOT EXISTS public.prices (
  id                bigserial PRIMARY KEY,
  created_at        timestamptz,
  updated_at        timestamptz,
  deleted_at        timestamptz,
  currency          varchar,
  price             bigint,
  item_type         public.item_type,
  stripe_full_id    varchar,
  stripe_deposit_id varchar,
  stripe_final_id   varchar,
  start_date        timestamptz,
  end_date          timestamptz
);

CREATE TABLE IF NOT EXISTS public.stripe_banks (
  id                   bigserial PRIMARY KEY,
  created_at           timestamptz,
  updated_at           timestamptz,
  deleted_at           timestamptz,
  currency             varchar,
  deposit_stripe_id    varchar,
  bank_stripe_id       varchar,
  amount               int,
  deposit_amount_paid  int,
  bank_amount_paid     int,
  status               public.payment_status,
  deposit_url          text,
  bank_url             text,
  expired_at           timestamptz
);

CREATE TABLE IF NOT EXISTS public.wm_coupon_codes (
  id         bigserial PRIMARY KEY,
  created_at timestamptz,
  updated_at timestamptz,
  deleted_at timestamptz,
  code       varchar,
  user_id    uuid REFERENCES public.users(id)   ON DELETE SET NULL,
  used       boolean,
  used_at    timestamptz,
  order_id   bigint REFERENCES public.orders(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS public.discount_infos (
  id            bigserial PRIMARY KEY,
  discount_code varchar,
  type          varchar,
  subscription  varchar,
  value         bigint,
  created_at    timestamptz,
  updated_at    timestamptz
);

-- Keep CSV's misspelling to preserve source
CREATE TYPE public.discount_type AS ENUM ('percentage','fixed','tier','other');
CREATE TABLE IF NOT EXISTS public.disocunt_codes (
  code        varchar PRIMARY KEY,
  type        public.discount_type,
  max_uses    bigint,
  created_at  timestamptz,
  updated_at  timestamptz
);

CREATE TABLE IF NOT EXISTS public.wm_coupon_usages (
  id         bigserial PRIMARY KEY,
  created_at timestamptz,
  updated_at timestamptz,
  deleted_at timestamptz,
  coupon_id  bigint REFERENCES public.wm_coupon_codes(id) ON DELETE CASCADE,
  user_id    uuid   REFERENCES public.users(id)           ON DELETE SET NULL,
  order_id   bigint REFERENCES public.orders(id)          ON DELETE SET NULL,
  used_at    timestamptz
);

CREATE TABLE IF NOT EXISTS public.whitelist_codes (
  code      varchar PRIMARY KEY,
  order_id  bigint REFERENCES public.orders(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS public.expired_items (
  id           bigserial PRIMARY KEY,
  created_at   timestamptz,
  updated_at   timestamptz,
  deleted_at   timestamptz,
  order_id     bigint REFERENCES public.orders(id) ON DELETE SET NULL,
  product_type public.item_type,
  product_id   varchar,
  item_id      bigint REFERENCES public.items(id)  ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS public.price_overrides (
  id                          bigserial PRIMARY KEY,
  created_at                  timestamptz,
  updated_at                  timestamptz,
  deleted_at                  timestamptz,
  currency                    varchar,
  base_price                  bigint,
  item_type                   public.item_type,
  base_stripe_full_id         varchar,
  base_stripe_deposit_id      varchar,
  base_stripe_final_id        varchar,
  partner_price               bigint,
  partner_stripe_full_id      varchar,
  partner_stripe_deposit_id   varchar,
  partner_stripe_final_id     varchar,
  middle_price                bigint,
  middle_stripe_full_id       varchar,
  middle_stripe_deposit_id    varchar,
  middle_stripe_final_id      varchar,
  lower_price                 bigint,
  lower_stripe_full_id        varchar,
  lower_stripe_deposit_id     varchar,
  lower_stripe_final_id       varchar,
  start_date                  timestamptz,
  end_date                    timestamptz
);

CREATE TABLE IF NOT EXISTS public.wmtx_rewards (
  id         bigserial PRIMARY KEY,
  created_at timestamptz,
  updated_at timestamptz,
  deleted_at timestamptz,
  order_id   bigint REFERENCES public.orders(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS public.coinbases (
  id              bigserial PRIMARY KEY,
  created_at      timestamptz,
  updated_at      timestamptz,
  deleted_at      timestamptz,
  currency        varchar,
  coinbase_id     varchar,
  subscription_id bigint REFERENCES public.subscriptions(id) ON DELETE SET NULL,
  amount          int,
  amount_paid     int,
  status          public.payment_status,
  url             text,
  expired_at      timestamptz,
  invoice_number  varchar
);

CREATE TABLE IF NOT EXISTS public.crypto_coms (
  id             bigserial PRIMARY KEY,
  created_at     timestamptz,
  updated_at     timestamptz,
  deleted_at     timestamptz,
  currency       varchar,
  crypto_com_id  varchar,
  amount         int,
  amount_paid    int,
  status         public.payment_status,
  url            text,
  expired_at     timestamptz,
  invoice_number varchar
);

CREATE TABLE IF NOT EXISTS public.stripe_fulls (
  id              bigserial PRIMARY KEY,
  created_at      timestamptz,
  updated_at      timestamptz,
  deleted_at      timestamptz,
  currency        varchar,
  stripe_id       varchar,
  subscription_id bigint REFERENCES public.subscriptions(id) ON DELETE SET NULL,
  amount          int,
  amount_paid     int,
  status          public.payment_status,
  url             text,
  expired_at      timestamptz
);

CREATE TABLE IF NOT EXISTS public.reservations (
  id         bigserial PRIMARY KEY,
  created_at timestamptz,
  updated_at timestamptz,
  deleted_at timestamptz,
  order_id   bigint REFERENCES public.orders(id) ON DELETE CASCADE,
  expires_at timestamptz
);

-- ===========================================================
-- Docs/Admin/API management
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.api_keys (
  id          bigserial PRIMARY KEY,
  created_at  timestamptz,
  updated_at  timestamptz,
  deleted_at  timestamptz,
  operator_id uuid REFERENCES public.operators(id) ON DELETE SET NULL,
  key_hash    varchar,
  name        varchar,
  active      boolean,
  expires_at  timestamptz,
  last_used   timestamptz
);

CREATE TABLE IF NOT EXISTS public.admins (
  id            bigserial PRIMARY KEY,
  created_at    timestamptz,
  updated_at    timestamptz,
  deleted_at    timestamptz,
  username      varchar,
  email         varchar,
  password_hash varchar,
  active        boolean,
  last_login    timestamptz
);

CREATE TABLE IF NOT EXISTS public.docs_sessions (
  id          varchar(36) PRIMARY KEY,
  api_key_id  bigint REFERENCES public.api_keys(id) ON DELETE SET NULL,
  token       varchar(64),
  ip_address  varchar(45),
  user_agent  text,
  expires_at  timestamptz,
  created_at  timestamptz,
  updated_at  timestamptz
);

CREATE TABLE IF NOT EXISTS public.admin_sessions (
  id         varchar(36) PRIMARY KEY,
  admin_id   bigint REFERENCES public.admins(id) ON DELETE CASCADE,
  token      varchar(64),
  ip_address varchar(45),
  user_agent text,
  expires_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.usages (
  id          bigserial PRIMARY KEY,
  created_at  timestamptz,
  updated_at  timestamptz,
  deleted_at  timestamptz,
  operator_id uuid REFERENCES public.operators(id) ON DELETE SET NULL,
  api_key_id  bigint REFERENCES public.api_keys(id) ON DELETE SET NULL,
  endpoint    varchar,
  status_code integer,
  duration    bigint,
  "timestamp" timestamptz
);

CREATE TABLE IF NOT EXISTS public.audit_logs (
  id          bigserial PRIMARY KEY,
  created_at  timestamptz,
  updated_at  timestamptz,
  deleted_at  timestamptz,
  action      varchar,
  description text,
  user_id     uuid,             -- could refer to public.users or admins; keeping loose
  operator_id uuid REFERENCES public.operators(id) ON DELETE SET NULL,
  api_key_id  bigint REFERENCES public.api_keys(id) ON DELETE SET NULL,
  ip_address  varchar,
  "timestamp" timestamptz
);

-- ===========================================================
-- Network / telemetry aggregates
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.sparkagg (
  id         varchar PRIMARY KEY,
  month_year varchar,   -- "YYYY_M"
  download   int,
  upload     int,
  uptime     int,
  downtime   int,
  data_total int,
  users      int
);

CREATE TABLE IF NOT EXISTS public.celldata (
  id         varchar PRIMARY KEY,
  month_year varchar,   -- "YYYY_M"
  cell_id    int,
  download   int,
  upload     int,
  users      int
);

CREATE TABLE IF NOT EXISTS public.cdrdata_tempagg (
  id         varchar PRIMARY KEY,
  month_year varchar,   -- "YYYY_M"
  cell_id    int,
  download   int,
  upload     int,
  users      int[]
);

CREATE TABLE IF NOT EXISTS public.airnodecellidmap (
  airnode_id        text REFERENCES public.airnodes(id) ON DELETE CASCADE,
  host_user_id      uuid REFERENCES public.users(id)     ON DELETE SET NULL,
  operator_user_id  uuid REFERENCES public.users(id)     ON DELETE SET NULL,
  cell_ids          int[],
  uptime_cell_ids   int[],
  PRIMARY KEY (airnode_id, host_user_id, operator_user_id)
);

CREATE TABLE IF NOT EXISTS public.cpeinfo (
  id                    varchar PRIMARY KEY,
  airnode_id            text REFERENCES public.airnodes(id) ON DELETE SET NULL,
  name                  varchar,
  type                  varchar,
  serial_number         varchar,
  last_data_update      timestamptz,
  ast_uptime_update     timestamptz,
  last_uptime_value     int,
  last_download_value   int,
  last_upload_value     int,
  previous_uptime_status text[],
  host_id               uuid REFERENCES public.users(id) ON DELETE SET NULL,
  operator_id           uuid REFERENCES public.users(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS public.sparkinfo (
  id                      varchar PRIMARY KEY,
  airnode_id              text REFERENCES public.airnodes(id) ON DELETE SET NULL,
  name                    varchar,
  type                    varchar,
  serial_number           varchar,
  last_data_update        timestamptz,
  last_uptime_update      timestamptz,
  last_uptime_value       int,
  last_download_value     int,
  last_upload_value       int,
  last_data_total_value   int,
  previous_uptime_status  text[],
  host_id                 uuid REFERENCES public.users(id) ON DELETE SET NULL,
  operator_id             uuid REFERENCES public.users(id) ON DELETE SET NULL,
  users                   int
);

-- ===========================================================
-- eSIM / telecom inventory
-- ===========================================================
CREATE TABLE IF NOT EXISTS dcc.users (
  id     varchar PRIMARY KEY,
  dcc_id varchar,
  email  varchar
);

CREATE TABLE IF NOT EXISTS public.plans (
  id          bigserial PRIMARY KEY,
  created_at  timestamptz,
  updated_at  timestamptz,
  deleted_at  timestamptz,
  dcc_id      varchar,
  name        varchar,
  description varchar,
  price       bigint,
  currency    varchar
);

CREATE TABLE IF NOT EXISTS public.lpas (
  id          bigserial PRIMARY KEY,
  created_at  timestamptz,
  updated_at  timestamptz,
  deleted_at  timestamptz,
  sub_id      varchar,
  lpa         varchar
);

CREATE TABLE IF NOT EXISTS public.addons (
  id          bigserial PRIMARY KEY,
  created_at  timestamptz,
  updated_at  timestamptz,
  deleted_at  timestamptz,
  dcc_id      varchar,
  name        varchar,
  description varchar,
  price       bigint,
  currency    varchar
);

CREATE TABLE IF NOT EXISTS public.wmnumbers (
  id                 bigserial PRIMARY KEY,
  created_at         timestamptz,
  updated_at         timestamptz,
  deleted_at         timestamptz,
  number             varchar,
  reserved           boolean,
  reserved_at        timestamptz,
  purchased          boolean,
  purchased_at       timestamptz,
  sub_id             varchar
);

CREATE TABLE IF NOT EXISTS public.inboundnumberorders (
  id                        bigserial PRIMARY KEY,
  created_at                timestamptz,
  updated_at                timestamptz,
  deleted_at                timestamptz,
  msisdn                    varchar,
  old_msisdn                varchar,
  order_id                  varchar,
  sub_id                    varchar,
  last_checked              timestamptz,
  status                    varchar,
  cancelled_email_sent      boolean,
  port_complete_email_sent  boolean,
  activation_time           timestamptz,
  activated                 boolean,
  activated_submitted       boolean,
  queue_id                  varchar
);

CREATE TABLE IF NOT EXISTS public.esims (
  id                  varchar(128) PRIMARY KEY,
  epoch_created       timestamptz,
  epoch_modified      timestamptz,
  epoch_removed       timestamptz,
  imsis               bytea,
  data_service_status varchar(50),
  voice_service_status varchar(50),
  sms_service_status  varchar(50),
  status              varchar(50),
  activation_code     varchar(256),
  user_id             uuid REFERENCES public.users(id) ON DELETE SET NULL,
  purchased_at        timestamptz,
  sales_channel       varchar(255),
  synced_at           timestamptz,
  reservation_status  varchar(16),
  reservation_id      varchar,
  nickname            varchar,
  operator_id         uuid REFERENCES public.operators(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS public.package_types (
  id                                integer PRIMARY KEY,
  name                              varchar(128),
  supported_countries               bytea,
  voice_usage_allowance_in_seconds  integer,
  data_usage_allowance_in_bytes     bigint,
  sms_usage_allowance_in_nums       integer,
  activation_time_allowance_in_seconds integer,
  activation_type                   varchar(50),
  data_earliest_activation          timestamptz,
  date_earliest_available           timestamptz,
  date_latest_available             timestamptz,
  notes                             text,
  epoch_created                     timestamptz,
  epoch_modified                    timestamptz,
  time_allowance                    bytea,
  status                            varchar(50),
  price                             numeric,
  date_deactivated                  timestamptz,
  description                       varchar(1024),
  synced_at                         timestamptz,
  allowed_imsi_ids                  integer[],
  scope                             varchar(255),
  logically_disabled                boolean,
  operator_id                       uuid REFERENCES public.operators(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS public.packages_active (
  id                              varchar PRIMARY KEY,
  sim_id                          varchar REFERENCES public.esims(id) ON DELETE CASCADE,
  date_created                    timestamptz,
  date_expiry                     timestamptz,
  date_activated                  timestamptz,
  date_terminated                 timestamptz,
  window_activation_start         timestamptz,
  window_activation_end           timestamptz,
  status                          varchar, -- "ACTIVE" etc.
  voice_usage_remaining_in_seconds integer,
  data_usage_remaining_in_bytes   bigint,
  sms_usage_remaining_in_nums     integer,
  package_type_id                 integer REFERENCES public.package_types(id) ON DELETE SET NULL,
  time_allowance_in_seconds       integer,
  dynamic_pacakge_time_allowance  bytea,
  synced_at                       timestamptz,
  operator_id                     uuid REFERENCES public.operators(id) ON DELETE SET NULL
);

-- ===========================================================
-- Contracts workflow
-- ===========================================================
CREATE TYPE public.workflow_status AS ENUM ('draft','pending','active','completed','canceled');

CREATE TABLE IF NOT EXISTS public.contract_groups (
  group_id           varchar PRIMARY KEY,
  workflow_id        varchar,
  dispatched_contract varchar,
  metadata           jsonb,
  status             public.workflow_status
);

CREATE TABLE IF NOT EXISTS public.participants (
  id               varchar PRIMARY KEY,
  email            varchar,
  terms_agreed     boolean,
  signed_at_time   bigint,
  reminder_sent    boolean,
  role             varchar
);

CREATE TYPE public.document_type AS ENUM ('pdf','doc','html','other');
CREATE TYPE public.contract_status AS ENUM ('draft','sent','viewed','signed','expired','void');

CREATE TABLE IF NOT EXISTS public.contracts (
  id                   varchar PRIMARY KEY,
  group_id             varchar REFERENCES public.contract_groups(group_id) ON DELETE CASCADE,
  template_id          varchar,
  document_type        public.document_type,
  expiry_time          bigint,
  reminder_time        bigint,
  document_id          varchar,
  invitiation_id       varchar,
  signature_request_id varchar,
  metadata             jsonb,
  status               public.contract_status
);

-- ===========================================================
-- Campaign / Messaging analytics (SendGrid-like)
-- ===========================================================
CREATE TABLE IF NOT EXISTS public.drops (
  id              bigserial PRIMARY KEY,
  name            varchar,
  description     varchar,
  sale_start_date timestamptz,
  sale_end_date   timestamptz,
  public          boolean,
  created_at      timestamptz,
  updated_at      timestamptz,
  deleted_at      timestamptz
);

CREATE TABLE IF NOT EXISTS public.messages (
  id            varchar PRIMARY KEY,
  from_email    varchar,
  msg_id        varchar,
  subject       varchar,
  to_email      varchar,
  status        varchar,
  opens_count   int,
  clicks_count  int,
  last_event_time timestamptz
);

CREATE TABLE IF NOT EXISTS public.browser_stats (
  id            varchar PRIMARY KEY,
  date          date,
  stats         varchar,
  type          varchar,
  name          varchar,
  created_at    date,
  metrics       double precision,
  clicks        int,
  unique_clicks int
);

CREATE TABLE IF NOT EXISTS public.alerts (
  id          varchar PRIMARY KEY,
  type        varchar,
  percentage  int,
  email_to    varchar,
  created_at  date,
  updated_at  date,
  frequency   varchar
);

CREATE TABLE IF NOT EXISTS public.categories (
  id                  varchar PRIMARY KEY,
  category            varchar,
  date                date,
  stats               varchar,
  type                varchar,
  name                varchar,
  metrics             double precision,
  blocks              int,
  bounce_drops        int,
  bounces             int,
  clicks              int,
  deferred            int,
  delivered           int,
  invalid_emails      int,
  opens               int,
  processed           int,
  requests            int,
  spam_report_drops   int,
  spam_reports        int,
  unique_clicks       int,
  unique_opens        int,
  unsubscribe_drops   int,
  unsubscribes        int
);

CREATE TABLE IF NOT EXISTS public.clients_phone (
  id            varchar PRIMARY KEY,
  date          date,
  stats         varchar,
  type          varchar,
  name          varchar,
  metrics       double precision,
  opens         int,
  unique_opens  int
);

CREATE TABLE IF NOT EXISTS public.clients_desktop (
  id            varchar PRIMARY KEY,
  date          date,
  stats         varchar,
  type          varchar,
  name          varchar,
  metrics       double precision,
  opens         int,
  unique_opens  int
);

CREATE TABLE IF NOT EXISTS public.clients_tablet (
  id                  varchar PRIMARY KEY,
  date                date,
  stats               varchar,
  type                varchar,
  name                varchar,
  metrics             double precision,
  blocks              int,
  bounce_drops        int,
  bounces             int,
  clicks              int,
  deferred            int,
  delivered           int,
  invalid_emails      int,
  opens               int,
  processed           int,
  requests            int,
  spam_report_drops   int,
  spam_reports        int,
  unique_clicks       int,
  unique_opens        int,
  unsubscribe_drops   int,
  unsubscribes        int
);

CREATE TABLE IF NOT EXISTS public.client_webmail (
  id                  varchar PRIMARY KEY,
  date                date,
  stats               varchar,
  type                varchar,
  name                varchar,
  metrics             double precision,
  blocks              int,
  bounce_drops        int,
  bounces             int,
  clicks              int,
  deferred            int,
  delivered           int,
  invalid_emails      int,
  opens               int,
  processed           int,
  requests            int,
  spam_report_drops   int,
  spam_reports        int,
  unique_clicks       int,
  unique_opens        int,
  unsubscribe_drops   int,
  unsubscribes        int
);

CREATE TABLE IF NOT EXISTS public.design_library (
  id                    varchar PRIMARY KEY,
  name                  varchar,
  generate_plain_content boolean,
  thumbnail_url         varchar,
  subject               varchar,
  created_at            date,
  updated_at            date,
  editor                varchar,
  categories            varchar
);

CREATE TABLE IF NOT EXISTS public.ips (
  id                 varchar PRIMARY KEY,
  ip                 varchar,
  pools              varchar,
  name               varchar,
  is_auto_warmup     boolean,
  added_at           date,
  updated_at         date,
  is_enabled         boolean,
  is_leased          boolean,
  is_parent_assigned boolean,
  after_key          varchar,
  before_key         varchar
);

CREATE TABLE IF NOT EXISTS public.geo_stats (
  id            varchar PRIMARY KEY,
  date          date,
  stats         varchar,
  type          varchar,
  name          varchar,
  metrics       double precision,
  clicks        int,
  opens         int,
  unique_clicks int,
  unqiue_opens  int
);

CREATE TABLE IF NOT EXISTS public.stats (
  id                  varchar PRIMARY KEY,
  date                date,
  blocks              int,
  bounce_drops        int,
  bounces             int,
  clicks              int,
  deferred            int,
  delivered           int,
  invalid_emails      int,
  opens               int,
  processed           int,
  requests            int,
  spam_report_drops   int,
  spam_reports        int,
  unique_clicks       int,
  unique_opens        int,
  unsubscribe_drops   int,
  unsubscribes        int
);

CREATE TABLE IF NOT EXISTS public.tx (
  id           varchar PRIMARY KEY,
  reference_id varchar,
  batch_id     varchar,
  user_id      uuid REFERENCES public.users(id) ON DELETE SET NULL,
  description  varchar,
  type         varchar,
  status       varchar,
  "timestamp"  timestamptz,
  updated_at   timestamptz,
  metadata     jsonb,
  credit       jsonb,
  debit        jsonb
);


-- ===========================================================
-- Indices commonly used
-- ===========================================================
CREATE INDEX IF NOT EXISTS idx_items_order_id ON public.items(order_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_user ON public.subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_orders_user ON public.orders(user_id);
CREATE INDEX IF NOT EXISTS idx_coinbases_sub ON public.coinbases(subscription_id);
CREATE INDEX IF NOT EXISTS idx_stripe_fulls_sub ON public.stripe_fulls(subscription_id);
CREATE INDEX IF NOT EXISTS idx_hex_interest_user ON public.hex_interest(user_id);


-- ===========================================================
-- FACT TABLES (hub records gathering many foreign keys)
-- From CSV: "Fact table 1" and "Fact table2"
-- ===========================================================

-- -------------------------
-- Fact table 1 (CSV row 5)
-- -------------------------
CREATE TABLE IF NOT EXISTS public.fact_core_1 (
  -- hex / nodehost / users / admin
  hexes_h3_id                       text REFERENCES public.hexes(h3_id) ON DELETE SET NULL,
  nodehost_id                       bigint REFERENCES public.nodehost(id) ON DELETE SET NULL,
  nodehost_building_id              integer,
  users_id                          uuid REFERENCES public.users(id) ON DELETE SET NULL,

  admin_actions_id                  bigint REFERENCES public.admin_actions(id) ON DELETE SET NULL,
  admin_actions_admin_id            uuid,  -- CSV lists but no FK target (admin_id in admin_actions has no separate table)
  admin_actions_user_id             uuid REFERENCES public.users(id) ON DELETE SET NULL,

  -- airnodes / types
  airnodes_id                       text REFERENCES public.airnodes(id) ON DELETE SET NULL,
  airnodes_host_id                  text,
  airnodes_operator_id              text,
  airnodes_parent_id                text,
  airnode_types_id                  text,  -- not defined in CSV entities; keep as free text

  -- sites and bridge
  sites_id                          text REFERENCES public.sites(id) ON DELETE SET NULL,
  site_with_airnodes_site_id        text REFERENCES public.sites(id) ON DELETE SET NULL,
  site_with_airnodes_airnode_id     text REFERENCES public.airnodes(id) ON DELETE SET NULL,

  -- (not defined as an entity; keep as fields only)
  airnode_with_childrens_id         text,
  airnode_with_childrens_parent_id  text,
  airnode_with_childrens_child_id   text,

  -- drops / (extra users repeated) / HLOM bridge
  drops_id                          bigint REFERENCES public.drops(id) ON DELETE SET NULL,
  users_id_2                        uuid REFERENCES public.users(id) ON DELETE SET NULL,

  host_location_operator_map_id                 uuid REFERENCES public.host_location_operator_map(id) ON DELETE SET NULL,
  host_location_operator_map_host_location_id   uuid REFERENCES public.host_locations(id) ON DELETE SET NULL,
  host_location_operator_map_operator_id        uuid REFERENCES public.operators(id) ON DELETE SET NULL,
  host_location_operator_map_airnodes_inventory_id uuid REFERENCES public.airnode_inventory(id) ON DELETE SET NULL,
  host_location_operator_map_thread_id          uuid REFERENCES public.threads(id) ON DELETE SET NULL,
  host_location_operator_map_contract_id        varchar(255),

  -- accounts (auth)
  accounts_id                        uuid REFERENCES public.accounts(id) ON DELETE SET NULL,
  accounts_provider_account_id       varchar(255),
  accounts_id_token                  text,
  accounts_user_id                   uuid REFERENCES public.users(id) ON DELETE SET NULL,

  -- hex interest
  hex_interest_hex_id                text,
  hex_interest_user_id               uuid,
  -- add FKs but allow NULLs to avoid cycle if needed
  CONSTRAINT fk_fact1_hex_interest_hex
    FOREIGN KEY (hex_interest_hex_id, hex_interest_user_id)
    REFERENCES public.hex_interest(hex_id, user_id) ON DELETE SET NULL,

  -- airnode inventory
  airnode_inventory_id               uuid REFERENCES public.airnode_inventory(id) ON DELETE SET NULL,
  airnode_inventory_payment_id       uuid REFERENCES public.payments(id) ON DELETE SET NULL,

  -- host locations
  host_locations_id                  uuid REFERENCES public.host_locations(id) ON DELETE SET NULL,
  host_locations_user_id             uuid REFERENCES public.users(id) ON DELETE SET NULL,
  host_locations_airnode_id          text REFERENCES public.airnodes(id) ON DELETE SET NULL,
  host_locations_hex_id              text REFERENCES public.hexes(h3_id) ON DELETE SET NULL,
  host_locations_address_id          uuid REFERENCES public.addresses(id) ON DELETE SET NULL,

  -- threads
  threads_id                         uuid REFERENCES public.threads(id) ON DELETE SET NULL,
  threads_host_location_id           uuid REFERENCES public.host_locations(id) ON DELETE SET NULL,
  threads_host_id                    uuid REFERENCES public.users(id) ON DELETE SET NULL,
  threads_operator_id                uuid REFERENCES public.users(id) ON DELETE SET NULL,

  -- others
  hexagons_id                        varchar(255) REFERENCES public.hexagons(id) ON DELETE SET NULL,
  partners_id                        uuid REFERENCES public.partners(id) ON DELETE SET NULL,

  addresses_id                       uuid REFERENCES public.addresses(id) ON DELETE SET NULL,
  payments_id                        uuid REFERENCES public.payments(id) ON DELETE SET NULL,
  stake_id                           uuid REFERENCES public.stake(id) ON DELETE SET NULL,
  payouts_id                         uuid REFERENCES public.payouts(id) ON DELETE SET NULL,
  messages_id                        varchar REFERENCES public.messages(id) ON DELETE SET NULL,

  design_library_id                  varchar REFERENCES public.design_library(id) ON DELETE SET NULL,
  geo_stats_id                       varchar REFERENCES public.geo_stats(id) ON DELETE SET NULL,
  ips_id                             varchar REFERENCES public.ips(id) ON DELETE SET NULL,
  stats_id                           varchar REFERENCES public.stats(id) ON DELETE SET NULL,

  clients_desktop_id                 varchar REFERENCES public.clients_desktop(id) ON DELETE SET NULL,
  clients_phone_id                   varchar REFERENCES public.clients_phone(id) ON DELETE SET NULL,
  alerts_id                          varchar REFERENCES public.alerts(id) ON DELETE SET NULL,
  browser_stats_id                   varchar REFERENCES public.browser_stats(id) ON DELETE SET NULL,
  categories_id                      varchar REFERENCES public.categories(id) ON DELETE SET NULL,
  clients_tablet_id                  varchar REFERENCES public.clients_tablet(id) ON DELETE SET NULL,
  client_webmail_id                  varchar REFERENCES public.client_webmail(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_fact1_hex ON public.fact_core_1(hexes_h3_id);
CREATE INDEX IF NOT EXISTS idx_fact1_user ON public.fact_core_1(users_id);

-- -------------------------
-- Fact table 2 (CSV row 45)
-- -------------------------
CREATE TABLE IF NOT EXISTS public.fact_core_2 (
  -- hex / nodehost (again)
  hexes_h3_id               text REFERENCES public.hexes(h3_id) ON DELETE SET NULL,
  nodehost_id               bigint REFERENCES public.nodehost(id) ON DELETE SET NULL,
  nodehost_building_id      integer,

  -- analytics / admin / api mgmt
  clients_tablet_id         varchar REFERENCES public.clients_tablet(id) ON DELETE SET NULL,
  client_webmail_id         varchar REFERENCES public.client_webmail(id) ON DELETE SET NULL,

  api_keys_id               bigint REFERENCES public.api_keys(id) ON DELETE SET NULL,
  admins_id                 bigint REFERENCES public.admins(id) ON DELETE SET NULL,
  admin_sessions_id         varchar(36) REFERENCES public.admin_sessions(id) ON DELETE SET NULL,
  operators_id              uuid REFERENCES public.operators(id) ON DELETE SET NULL,
  docs_sessions_id          varchar(36) REFERENCES public.docs_sessions(id) ON DELETE SET NULL,
  usages_id                 bigint REFERENCES public.usages(id) ON DELETE SET NULL,
  audit_logs_id             bigint REFERENCES public.audit_logs(id) ON DELETE SET NULL,

  -- ledger / tx / earnings / telemetry
  account_id                uuid REFERENCES public.account(id) ON DELETE SET NULL,
  tx_id                     varchar REFERENCES public.tx(id) ON DELETE SET NULL,
  earnings_id               text REFERENCES cdr.earnings(id) ON DELETE SET NULL,

  celldata_id               varchar REFERENCES public.celldata(id) ON DELETE SET NULL,
  celldata_cell_id          integer,
  sparkagg_id               varchar REFERENCES public.sparkagg(id) ON DELETE SET NULL,

  -- airnode cell map (CSV typo "airnodecellimap")
  airnodecellidmap_airnode_id       text REFERENCES public.airnodecellidmap(airnode_id) ON DELETE SET NULL,
  airnodecellidmap_host_user_id     uuid,
  airnodecellidmap_operator_user_id uuid,

  cdrdata_tempagg_id        varchar REFERENCES public.cdrdata_tempagg(id) ON DELETE SET NULL,

  cpeinfo_id                varchar REFERENCES public.cpeinfo(id) ON DELETE SET NULL,
  sparkinfo_id              varchar REFERENCES public.sparkinfo(id) ON DELETE SET NULL,

  wmnumbers_id              bigint REFERENCES public.wmnumbers(id) ON DELETE SET NULL,

  -- DCC users (CSV had a separate users table for DCC)
  dcc_users_id              varchar REFERENCES dcc.users(id) ON DELETE SET NULL,

  lpas_id                   bigint REFERENCES public.lpas(id) ON DELETE SET NULL,
  plans_id                  bigint REFERENCES public.plans(id) ON DELETE SET NULL,
  inboundnumberorders_id    bigint REFERENCES public.inboundnumberorders(id) ON DELETE SET NULL,
  addons_id                 bigint REFERENCES public.addons(id) ON DELETE SET NULL,
  esims_id                  varchar(128) REFERENCES public.esims(id) ON DELETE SET NULL,
  packages_active_id        varchar REFERENCES public.packages_active(id) ON DELETE SET NULL,
  package_types_id          integer REFERENCES public.package_types(id) ON DELETE SET NULL,

  -- contracts
  contractgroup_group_id    varchar REFERENCES public.contract_groups(group_id) ON DELETE SET NULL,
  participant_id            varchar REFERENCES public.participants(id) ON DELETE SET NULL,
  contract_id               varchar REFERENCES public.contracts(id) ON DELETE SET NULL,

  -- commerce
  orders_id                 bigint REFERENCES public.orders(id) ON DELETE SET NULL,
  items_id                  bigint REFERENCES public.items(id) ON DELETE SET NULL,
  user_linked_affiliates_user_id uuid REFERENCES cart.user_linked_affiliates(user_id) ON DELETE SET NULL,
  prices_id                 bigint REFERENCES public.prices(id) ON DELETE SET NULL,
  discount_infos_id         bigint REFERENCES public.discount_infos(id) ON DELETE SET NULL,
  expired_items_id          bigint REFERENCES public.expired_items(id) ON DELETE SET NULL,
  wmtx_rewards_id           bigint REFERENCES public.wmtx_rewards(id) ON DELETE SET NULL,
  reservations_id           bigint REFERENCES public.reservations(id) ON DELETE SET NULL,
  wm_coupon_codes_id        bigint REFERENCES public.wm_coupon_codes(id) ON DELETE SET NULL,
  wm_coupon_usages_id       bigint REFERENCES public.wm_coupon_usages(id) ON DELETE SET NULL,
  subscriptions_id          bigint REFERENCES public.subscriptions(id) ON DELETE SET NULL,
  price_overrides_id        bigint REFERENCES public.price_overrides(id) ON DELETE SET NULL,
  coinbases_id              bigint REFERENCES public.coinbases(id) ON DELETE SET NULL,
  stripe_fulls_id           bigint REFERENCES public.stripe_fulls(id) ON DELETE SET NULL,
  crypto_coms_id            bigint REFERENCES public.crypto_coms(id) ON DELETE SET NULL,
  stripe_banks_id           bigint REFERENCES public.stripe_banks(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_fact2_hex ON public.fact_core_2(hexes_h3_id);
CREATE INDEX IF NOT EXISTS idx_fact2_orders ON public.fact_core_2(orders_id);
