-- Notifications, push tokens and the admin audit trail.

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  notification_type text not null check (notification_type in (
    'promo', 'ride', 'rental', 'pasuyo', 'payment', 'wallet',
    'verification', 'system', 'safety', 'rating'
  )),
  title text not null check (length(trim(title)) > 0),
  body text not null check (length(trim(body)) > 0),
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index notifications_profile_idx
  on public.notifications (profile_id, created_at desc);

create index notifications_unread_idx
  on public.notifications (profile_id, created_at desc)
  where read_at is null;

create table public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  platform public.device_platform not null,
  token text not null check (length(trim(token)) > 0),
  is_active boolean not null default true,
  last_used_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint device_tokens_token_key unique (token)
);

create index device_tokens_profile_idx
  on public.device_tokens (profile_id)
  where is_active;

create table public.admin_audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles (id) on delete set null,
  action text not null check (length(trim(action)) > 0),
  entity_type text not null check (length(trim(entity_type)) > 0),
  entity_id uuid,
  before_state jsonb,
  after_state jsonb,
  ip_address inet,
  user_agent text,
  created_at timestamptz not null default now()
);

create index admin_audit_logs_actor_idx
  on public.admin_audit_logs (actor_id, created_at desc);

create index admin_audit_logs_entity_idx
  on public.admin_audit_logs (entity_type, entity_id, created_at desc);

create index admin_audit_logs_created_idx
  on public.admin_audit_logs (created_at desc);

create trigger device_tokens_set_updated_at
  before update on public.device_tokens
  for each row execute function public.set_updated_at();
