-- Local test: each statement must fail on a constraint. Run as postgres on a scratch database after
-- migrations, gyms_ontario.sql and dev_synthetic.sql. Prints PASS/FAIL per case; ends with an error if any failed.
\o /dev/null
create temp table results (name text, ok boolean);
create or replace function pg_temp.expect_fail(name text, stmt text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
    insert into results values (name, false);
  exception when others then
    insert into results values (name, true);
  end;
end $$;

select pg_temp.expect_fail('grade_min > grade_max',
  $q$update boulderme.profiles set grade_min = 9, grade_max = 2 where display_name = 'Test Ada'$q$);
select pg_temp.expect_fail('grade above V17',
  $q$update boulderme.profiles set grade_max = 18 where display_name = 'Test Ada'$q$);
select pg_temp.expect_fail('unknown style',
  $q$update boulderme.profiles set styles = '{yoga}' where display_name = 'Test Ada'$q$);
select pg_temp.expect_fail('discoverable without adult confirmation',
  $q$update boulderme.profiles set discoverable = true, adult_confirmed = false where display_name = 'Test Cleo'$q$);
select pg_temp.expect_fail('slot shorter than 30 minutes',
  $q$insert into boulderme.availability_slots (account_id, weekday, start_minute, end_minute, time_zone)
     values ('00000000-0000-4000-8000-000000000001', 1, 600, 600, 'America/Toronto')$q$);
select pg_temp.expect_fail('slot off the 30 minute grid',
  $q$insert into boulderme.availability_slots (account_id, weekday, start_minute, end_minute, time_zone)
     values ('00000000-0000-4000-8000-000000000001', 1, 615, 700, 'America/Toronto')$q$);
select pg_temp.expect_fail('invite yourself',
  $q$insert into boulderme.invitations (sender_id, recipient_id, gym_id, proposed_start_at, expires_at)
     select '00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001', id, now() + interval '1 day', now() + interval '1 day'
     from boulderme.gyms limit 1$q$);

-- one pending invitation per unordered pair
insert into boulderme.invitations (sender_id, recipient_id, gym_id, proposed_start_at, expires_at)
select '00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002', id, now() + interval '1 day', now() + interval '1 day'
from boulderme.gyms limit 1;
select pg_temp.expect_fail('second pending invite, reversed pair',
  $q$insert into boulderme.invitations (sender_id, recipient_id, gym_id, proposed_start_at, expires_at)
     select '00000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001', id, now() + interval '2 days', now() + interval '2 days'
     from boulderme.gyms limit 1$q$);
select pg_temp.expect_fail('accepted without a chat',
  $q$update boulderme.invitations set status = 'accepted' where status = 'pending'$q$);
select pg_temp.expect_fail('chat pair out of order',
  $q$insert into boulderme.chats (account_low_id, account_high_id)
     values ('00000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000001')$q$);
select pg_temp.expect_fail('block yourself',
  $q$insert into boulderme.blocks (blocker_id, blocked_id)
     values ('00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001')$q$);
select pg_temp.expect_fail('unknown report reason',
  $q$insert into boulderme.reports (reporter_id, reported_id, context, reason)
     values ('00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002', 'profile', 'rude')$q$);
select pg_temp.expect_fail('gym website must be https',
  $q$insert into boulderme.gyms (slug, name, city, region, country, is_bouldering_only, website_url)
     values ('bad-gym', 'Bad Gym', 'Toronto', 'CA-ON', 'CA', true, 'http://example.com')$q$);

-- happy path: accept opens the chat
with c as (insert into boulderme.chats (account_low_id, account_high_id)
           values ('00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002') returning id)
update boulderme.invitations set status = 'accepted', chat_id = (select id from c), responded_at = now() where status = 'pending';
insert into boulderme.chat_messages (chat_id, sender_id, body)
select id, account_low_id, 'See you at the wall' from boulderme.chats;
insert into results select 'accept + message happy path', count(*) = 1 from boulderme.chat_messages;
select pg_temp.expect_fail('empty message',
  $q$insert into boulderme.chat_messages (chat_id, sender_id, body)
     select id, account_low_id, '' from boulderme.chats limit 1$q$);

\o
select case when ok then 'PASS' else 'FAIL' end as result, name from results order by ok, name;
do $$ begin if exists (select 1 from results where not ok) then raise exception 'constraint tests failed'; end if; end $$;
