-- 0002_account_deletion.sql
-- Adds boulderme.delete_account(), used by the Worker's DELETE /v1/me and by the operator
-- runbook (OPERATIONS.md), so both delete exactly the same things. Also lets boulderme_api
-- delete a member's own gym suggestions, which account deletion removes.
-- Runs as `postgres`. Touches nothing outside schema `boulderme`.

begin;

grant delete on boulderme.gym_requests to boulderme_api;

-- SECURITY INVOKER: runs with the caller's privileges (boulderme_api, or postgres for the
-- operator), so it can do nothing the Worker could not already do statement by statement.
create function boulderme.delete_account(p_account_id uuid, p_now timestamptz) returns void
language plpgsql set search_path = '' as $$
begin
  -- Lock the account; deleting twice is a no-op.
  perform 1 from boulderme.accounts where id = p_account_id and status <> 'deleted' for update;
  if not found then
    return;
  end if;

  -- The Apple subject hash moves to a tombstone so the account cannot be resurrected while
  -- Apple revocation is pending. A later new account for the same Apple ID gets a new id.
  insert into boulderme.tombstones (apple_sub_hash, account_id, deleted_at, apple_revocation_status, attempts, next_attempt_at)
  select a.apple_sub_hash, a.id, p_now,
         case when a.apple_refresh_token_enc is null then 'not_needed' else 'pending' end, 0, p_now
  from boulderme.accounts a where a.id = p_account_id
  on conflict (apple_sub_hash) do update
    set account_id = excluded.account_id, deleted_at = excluded.deleted_at,
        apple_revocation_status = excluded.apple_revocation_status, attempts = 0,
        next_attempt_at = excluded.next_attempt_at;

  -- Open invitations end: pending ones and accepted sessions that have not finished.
  update boulderme.invitations i set status = 'cancelled'
  where (i.sender_id = p_account_id or i.recipient_id = p_account_id)
    and ((i.status = 'pending' and i.expires_at > p_now)
      or (i.status = 'accepted' and i.proposed_start_at + i.duration_minutes * interval '1 minute' > p_now));
  update boulderme.invitations set status = 'expired'
  where (sender_id = p_account_id or recipient_id = p_account_id) and status = 'pending';

  update boulderme.chats set status = 'closed'
  where p_account_id in (account_low_id, account_high_id) and status = 'open';

  delete from boulderme.chat_messages where sender_id = p_account_id;
  delete from boulderme.chat_read_states where account_id = p_account_id;
  delete from boulderme.profiles where account_id = p_account_id;
  delete from boulderme.gym_access where account_id = p_account_id;
  delete from boulderme.availability_slots where account_id = p_account_id;
  delete from boulderme.blocks where blocker_id = p_account_id;
  delete from boulderme.gym_requests where account_id = p_account_id;
  delete from boulderme.idempotency_keys where account_id = p_account_id;
  update boulderme.refresh_sessions set revoked_at = p_now where account_id = p_account_id and revoked_at is null;

  -- The row stays (invitations, chats and reports point at it) but carries nothing personal
  -- except the encrypted Apple token, which is erased once revocation finishes.
  update boulderme.accounts
  set status = 'deleted', deleted_at = p_now, apple_sub_hash = 'deleted:' || id::text
  where id = p_account_id;
end $$;

revoke all on function boulderme.delete_account(uuid, timestamptz) from public, anon, authenticated, service_role;
grant execute on function boulderme.delete_account(uuid, timestamptz) to boulderme_api;

insert into boulderme.schema_migrations (version) values ('0002_account_deletion');

commit;
