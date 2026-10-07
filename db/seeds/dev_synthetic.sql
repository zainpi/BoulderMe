-- Synthetic test data for local and staging databases. NEVER run against production.
-- Needs seeds/gyms_ontario.sql first. Everything here is fake and safe to wipe.
begin;
do $$
begin
  if current_setting('boulderme.allow_synthetic', true) is distinct from 'on' then
    raise exception 'Refusing to seed synthetic data. Run with: set boulderme.allow_synthetic = on;';
  end if;
end $$;

insert into boulderme.accounts (id, apple_sub_hash) values
  ('00000000-0000-4000-8000-000000000001', 'synthetic-apple-sub-1'),
  ('00000000-0000-4000-8000-000000000002', 'synthetic-apple-sub-2'),
  ('00000000-0000-4000-8000-000000000003', 'synthetic-apple-sub-3')
on conflict do nothing;

insert into boulderme.profiles (account_id, display_name, grade_min, grade_max, styles, intro, discoverable, adult_confirmed, discovery_explained) values
  ('00000000-0000-4000-8000-000000000001', 'Test Ada',  3, 5, '{slab,crimps}',     'Synthetic test member.', true,  true, true),
  ('00000000-0000-4000-8000-000000000002', 'Test Ben',  4, 6, '{overhang,power}',  'Synthetic test member.', true,  true, true),
  ('00000000-0000-4000-8000-000000000003', 'Test Cleo', 0, 2, '{vertical}',        null,                     false, true, false)
on conflict do nothing;

insert into boulderme.gym_access (account_id, gym_id, access_type)
select a.id, g.id, a.access
from (values ('00000000-0000-4000-8000-000000000001'::uuid, 'membership'),
             ('00000000-0000-4000-8000-000000000002'::uuid, 'guest_pass'),
             ('00000000-0000-4000-8000-000000000003'::uuid, 'membership')) a(id, access)
cross join lateral (select id from boulderme.gyms where is_active order by city, name limit 1) g
on conflict do nothing;

insert into boulderme.availability_slots (account_id, weekday, start_minute, end_minute, time_zone) values
  ('00000000-0000-4000-8000-000000000001', 2, 1080, 1260, 'America/Toronto'),
  ('00000000-0000-4000-8000-000000000002', 2, 1110, 1290, 'America/Toronto'),
  ('00000000-0000-4000-8000-000000000002', 6, 600, 780, 'America/Toronto');
commit;
