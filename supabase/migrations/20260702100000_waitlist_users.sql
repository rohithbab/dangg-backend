create table public.waitlist_users (
  id         uuid        primary key default gen_random_uuid(),
  email      text        not null,
  phone      text        not null,
  created_at timestamptz not null default now()
);

-- Case-insensitive unique email — prevents duplicate signups.
create unique index waitlist_users_email_idx on public.waitlist_users (lower(email));

-- Unique phone too — one slot per number.
create unique index waitlist_users_phone_idx on public.waitlist_users (phone);
