-- Policy acceptance audit trail.
--
-- Users accept a *bundle* of legal policies (Privacy, Terms, Community, Coins,
-- Deletion, Safety, Copyright, Disclaimer) at a single version. We record one
-- row per (user, version) so re-accepting the same version is idempotent, and
-- a version bump (v1.0 -> v1.1) produces a new row — giving a clean audit trail
-- of who agreed to what, when, from which app build.
--
-- Keyed off auth.users, NOT public.users: consent is captured right after OTP
-- verification, *before* the public.users row is provisioned by
-- complete_signup_profile().

create table if not exists public.policy_acceptances (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  phone          text,
  policy_version text not null,
  app_version    text,
  accepted_at    timestamptz not null default now()
);

create index if not exists policy_acceptances_user_idx
  on public.policy_acceptances (user_id);

-- One acceptance per (user, version): re-tapping "I agree" just refreshes it.
create unique index if not exists policy_acceptances_user_version_uidx
  on public.policy_acceptances (user_id, policy_version);

alter table public.policy_acceptances enable row level security;

drop policy if exists "policy_acceptances_select_own" on public.policy_acceptances;
create policy "policy_acceptances_select_own"
  on public.policy_acceptances
  for select
  using (auth.uid() = user_id);

drop policy if exists "policy_acceptances_insert_own" on public.policy_acceptances;
create policy "policy_acceptances_insert_own"
  on public.policy_acceptances
  for insert
  with check (auth.uid() = user_id);

-- Records the caller's acceptance of a policy version. Captures the phone from
-- auth.users server-side so the audit row is self-contained. Idempotent on
-- (user, version).
create or replace function public.record_policy_acceptance(
  p_policy_version text,
  p_app_version    text default null
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_phone text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select phone into v_phone from auth.users where id = auth.uid();

  insert into public.policy_acceptances (user_id, phone, policy_version, app_version)
  values (auth.uid(), v_phone, p_policy_version, coalesce(p_app_version, ''))
  on conflict (user_id, policy_version)
  do update set
    accepted_at = now(),
    app_version = excluded.app_version,
    phone       = excluded.phone;
end;
$$;

grant execute on function public.record_policy_acceptance(text, text) to authenticated;

-- Returns the caller's most-recently accepted policy version (or no rows). The
-- client compares it to the app's CURRENT_POLICY_VERSION to decide whether to
-- re-prompt on a policy bump.
create or replace function public.get_policy_acceptance()
returns table (policy_version text, accepted_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select policy_version, accepted_at
  from public.policy_acceptances
  where user_id = auth.uid()
  order by accepted_at desc
  limit 1;
$$;

grant execute on function public.get_policy_acceptance() to authenticated;
