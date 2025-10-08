erDiagram

  %% =========================
  %% Schemas: public / affiliate / cdr / cart
  %% =========================

  %% ---- public.hexes
  public_hexes {
    text h3_id PK
    int  resolution
    varchar country
    varchar country_alpha_3
    varchar country_alpha_2
    geometry geom
    double lng
    double lat
    double h3_cell_area
    varchar status
    varchar name
    varchar boundary_type
    double bearing_angle
    varchar bearing_label
    varchar state_alpha_2
    varchar state_fips
    double pop_total_h5
    double housing_total_h5
    double housing_occupied_h5
    double pop_density_h5
    double hex_estimated_value
    double hex_starting_bid
    double hex_current_bid
    varchar current_bid_token
    timestamptz last_updated
    int number_of_bids
    timestamptz end_date
    varchar highest_bidder
    varchar previous_highest_bidder
    timestamptz completion_date
    int number_of_agents
    int number_of_watchers
    varchar next_bid
  }

  %% ---- public.users
  public_users {
    uuid id PK
    varchar name
    citext email UK
    citext username
    varchar role
    boolean is_partner
    boolean email_verified
    varchar image
    varchar display_username
    varchar billing_address
    timestamptz created_at
    timestamptz updated_at
  }

  %% ---- public.airnodes
  public_airnodes {
    text id PK
    int  type
    int  purchase_status
    int  initial_puchase_status
    int  initial_purchase_status
    int  provisioning_status
    text host_id
    text operator_id
    jsonb hardware_cells_ids
    timestamptz updated_at
    text parent_id
    int  version
    text name
    text batch_name
    timestamptz created_at
    timestamptz deleted_at
  }

  %% ---- public.nodehost (FK -> hexes)
  public_nodehost {
    bigserial id PK
    text h3_id FK
    text host_name
    text host_email
    text agent_name
    text agent_email
    int  building_id
    text building_address
    double building_height_m
    varchar building_type
    geometry geom
    int  building_floor_count
  }

  %% ---- public.sites
  public_sites {
    text id PK
    text name
    double latitude
    double longitude
    text country
    text city
    text state
    jsonb hexes
    double apex_lat
    double apex_lng
  }

  %% ---- bridge: public.sites_with_airnodes
  public_sites_with_airnodes {
    text site_id PK, FK
    text airnode_id PK, FK
  }

  %% ---- public.addresses
  public_addresses {
    uuid id PK
    timestamptz created_at
    timestamptz updated_at
  }

  %% ---- public.operators
  public_operators {
    uuid id PK
    text name
    text description
    boolean active
    timestamptz created_at
    timestamptz updated_at
  }

  %% ---- public.host_locations
  public_host_locations {
    uuid id PK
    uuid user_id FK
    text airnode_id FK
    varchar height
    varchar power_supply
    text hex_id FK
    boolean approved
    boolean listed
    double longitude
    double latitude
    varchar zipcode
    varchar phone
    varchar property_phone
    uuid address_id FK
    varchar equipment
    varchar instructions
    geometry geom
    timestamptz created_at
    timestamptz updated_at
  }

  %% ---- public.payments
  public_payments {
    uuid id PK
    varchar provider
    varchar provider_id
    uuid address_id FK
    varchar currency
    bigint total
    bigint paid
    uuid user_id FK
    boolean is_expired
    text bank_transfer_url
    text bank_transfer_payment_intent_id
    text bank_transfer_checkout_session_id
    text jira_order_id
    text freshdesk_id
    text node_ids
    timestamptz created_at
    timestamptz updated_at
  }

  %% ---- public.airnode_inventory
  public_airnode_inventory {
    uuid id PK
    varchar uuid
    varchar model
    uuid payment_id FK
    boolean is_reserved
    timestamptz status_deposit_paid
    timestamptz status_purchased
    timestamptz status_shipped
    timestamptz status_delivered
    timestamptz status_waiting_on_deployment
    timestamptz status_deployed
    timestamptz status_provisioning
    timestamptz status_active
    timestamptz created_at
    timestamptz updated_at
  }

  %% ---- public.threads
  public_threads {
    uuid id PK
    uuid host_location_id FK
    uuid host_id FK
    uuid operator_id FK
    timestamptz created_at
    timestamptz updated_at
  }

  %% ---- public.host_location_operator_map
  public_hlom {
    uuid id PK
    uuid host_location_id FK
    uuid operator_id FK
    uuid airnode_inventory_id FK
    uuid thread_id FK
    timestamptz host_terms_accepted
    timestamptz operator_terms_accepted
    varchar contract_id
    timestamptz world_mobile_terms_processed
    timestamptz created_at
    timestamptz updated_at
  }

  %% ---- public.accounts
  public_accounts {
    uuid id PK
    varchar type
    varchar provider
    varchar provider_account_id
    varchar refresh_token
    varchar access_token
    bigint  expires_at
    varchar token_type
    varchar scope
    text    id_token
    varchar session_state
    uuid user_id FK
    timestamptz access_token_expires_at
    timestamptz refresh_token_expires_at
    varchar password
    timestamptz created_at
    timestamptz updated_at
  }

  %% ---- public.admin_actions
  public_admin_actions {
    bigserial id PK
    uuid admin_id
    uuid user_id FK
    varchar user_email
    varchar action_status
    timestamptz created_at
  }

  %% ---- affiliate.users
  affiliate_users {
    uuid id PK
    varchar name
    citext email UK
    citext username
    varchar role
    boolean is_partner
    boolean email_verified
    varchar image
    varchar display_username
    varchar billing_address
    timestamptz created_at
    timestamptz updated_at
  }

  %% ---- cdr.earnings
  cdr_earnings {
    text id PK
    date month_start
    text month_year_raw
    text node_id FK
    text node_type
    uuid affiliate_user_id FK
    bigint operator_total
    bigint host_total
    bigint host_operator_total
    timestamptz created_at
  }

  %% ---- cart.user_linked_affiliates
  cart_user_linked_affiliates {
    uuid user_id PK, FK
    text affiliate_code PK
    timestamptz created_at
    timestamptz updated_at
    timestamptz deleted_at
  }

  %% =========================
  %% Relationships
  %% =========================

  public_hexes ||--o{ public_nodehost : "h3_id → h3_id"
  public_hexes ||--o{ public_host_locations : "hex_id → h3_id"

  public_users ||--o{ public_host_locations : "user_id → id"
  public_users ||--o{ public_threads : "host_id → id"
  public_users ||--o{ public_threads : "operator_id → id"
  public_users ||--o{ public_accounts : "user_id → id"
  public_users ||--o{ public_payments : "user_id → id"
  public_users ||--o{ public_admin_actions : "user_id → id"
  public_users ||--o{ cart_user_linked_affiliates : "user_id → id"

  public_airnodes ||--o{ public_host_locations : "airnode_id → id"
  public_airnodes ||--o{ cdr_earnings : "node_id → id"
  public_airnodes }o--o{ public_sites_with_airnodes : "id ↔ airnode_id"

  public_sites ||--o{ public_sites_with_airnodes : "id → site_id"

  public_addresses ||--o{ public_host_locations : "address_id → id"
  public_addresses ||--o{ public_payments : "address_id → id"

  public_payments ||--o{ public_airnode_inventory : "id → payment_id"

  public_operators ||--o{ public_hlom : "operator_id → id"

  public_host_locations ||--o{ public_threads : "id → host_location_id"
  public_host_locations ||--o{ public_hlom : "id → host_location_id"

  public_airnode_inventory ||--o{ public_hlom : "id → airnode_inventory_id"

  public_threads ||--o{ public_hlom : "id → thread_id"

  affiliate_users ||--o{ cdr_earnings : "id → affiliate_user_id"
