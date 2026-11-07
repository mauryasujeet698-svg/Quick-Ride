create table if not exists public.device_push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token text not null unique,
  app_role text not null check (app_role in ('customer', 'driver', 'admin')),
  platform text not null check (platform in ('android', 'ios', 'web')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create index if not exists device_push_tokens_user_role_idx
  on public.device_push_tokens(user_id, app_role);

alter table public.device_push_tokens enable row level security;
revoke all on table public.device_push_tokens from anon;
revoke all on table public.device_push_tokens from authenticated;
grant select, insert, update, delete on table public.device_push_tokens to authenticated;
grant all on table public.device_push_tokens to service_role;

create policy device_push_tokens_select_own on public.device_push_tokens
  for select to authenticated using (auth.uid() = user_id);
create policy device_push_tokens_insert_own on public.device_push_tokens
  for insert to authenticated with check (auth.uid() = user_id);
create policy device_push_tokens_update_own on public.device_push_tokens
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy device_push_tokens_delete_own on public.device_push_tokens
  for delete to authenticated using (auth.uid() = user_id);
