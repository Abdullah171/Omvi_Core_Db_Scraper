BEGIN;

-- 1) Make sure the three builders exist (affiliate.users).
-- (Your schema maps this model as affiliate_users in Prisma, but the table name is affiliate.users.)
INSERT INTO affiliate.users (id, name, email, username, role, is_partner, email_verified, image, display_username, billing_address, created_at, updated_at)
VALUES
  ('aaaa1111-bbbb-2222-cccc-3333dddd4444','Sophie Martin','sophie.martin@citycell.co.uk','SOPHIE_MARTIN','affiliate',false,true,NULL,'SophieM','Camden High St, London','2025-07-06T09:00:00Z',now()),
  ('bbbb2222-cccc-3333-dddd-4444eeee5555','Bilal Ahmed','bilal.ahmed@sindhnet.pk','BILAL_AHMED','affiliate',false,true,NULL,'BilalA','Clifton Block 5, Karachi','2025-07-07T07:45:00Z',now()),
  ('cccc3333-dddd-4444-eeee-5555ffff6666','Emma Jones','emma.jones@northmesh.uk','EMMA_JONES','affiliate',false,true,NULL,'EmmaJ','Deansgate, Manchester','2025-07-08T08:15:00Z',now())
ON CONFLICT (id) DO NOTHING;

-- 2) Make sure the example public users exist (for joining later).
-- (These already exist in your sample, but we include them idempotently.)
INSERT INTO public.users (id, name, email, username, role, is_partner, email_verified, image, display_username, billing_address, created_at, updated_at)
VALUES
  ('10101010-aaaa-bbbb-cccc-111111111111','Olivia Turner','olivia.turner@metronova.us','olivia_turner','operator',true,true,NULL,'OliviaT','99 Wall St, New York, USA','2025-07-01T12:00:00Z',now()),
  ('20202020-bbbb-cccc-dddd-222222222222','James Walker','james.walker@citycell.co.uk','james_walker','host',false,true,NULL,'JamesW','10 Whitehall, London, UK','2025-07-02T10:00:00Z',now()),
  ('30303030-cccc-dddd-eeee-333333333333','Ayesha Khan','ayesha.khan@sindhnet.pk','ayesha_khan','operator',true,true,NULL,'AyeshaK','Shahrah-e-Faisal, Karachi, Pakistan','2025-07-03T09:00:00Z',now()),
  ('40404040-dddd-eeee-ffff-444444444444','Daniel Green','daniel.green@baymesh.net','daniel_green','host',false,true,NULL,'DanielG','1 Market St, San Francisco, USA','2025-07-04T11:00:00Z',now()),
  ('50505050-eeee-ffff-aaaa-555555555555','Zainab Ali','zainab.ali@punjabmesh.pk','zainab_ali','affiliate',false,true,NULL,'ZainabA','Gulberg III, Lahore, Pakistan','2025-07-05T08:30:00Z',now()),
  ('60606060-ffff-aaaa-bbbb-666666666666','Harry Wilson','harry.wilson@northmesh.uk','harry_wilson','operator',true,true,NULL,'HarryW','1 St Peter’s Sq, Manchester, UK','2025-07-06T10:45:00Z',now())
ON CONFLICT (id) DO NOTHING;

-- 3) Link users to builders by setting affiliate_code = builder.username
--    (So our counting queries work without ambiguity.)
--    Primary key on this table is (user_id, affiliate_code), so we protect with ON CONFLICT DO NOTHING.
INSERT INTO cart.user_linked_affiliates (user_id, affiliate_code, created_at, updated_at, deleted_at)
VALUES
  -- Sophie (code = 'SOPHIE_MARTIN') gets two affiliates
  ('20202020-bbbb-cccc-dddd-222222222222', 'SOPHIE_MARTIN', '2025-07-12T10:00:00Z', now(), NULL),  -- James Walker
  ('40404040-dddd-eeee-ffff-444444444444', 'SOPHIE_MARTIN', '2025-07-12T11:00:00Z', now(), NULL),  -- Daniel Green

  -- Bilal (code = 'BILAL_AHMED') gets two affiliates
  ('30303030-cccc-dddd-eeee-333333333333', 'BILAL_AHMED', '2025-07-12T12:00:00Z', now(), NULL),    -- Ayesha Khan
  ('50505050-eeee-ffff-aaaa-555555555555', 'BILAL_AHMED', '2025-07-12T13:00:00Z', now(), NULL),    -- Zainab Ali

  -- Emma (code = 'EMMA_JONES') gets one affiliate
  ('60606060-ffff-aaaa-bbbb-666666666666', 'EMMA_JONES', '2025-07-12T14:00:00Z', now(), NULL)      -- Harry Wilson
ON CONFLICT DO NOTHING;

COMMIT;
