-- ============ stories ============
create table public.stories (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  caption text not null default '',
  media_url text,
  gradient text not null default 'from-violet-500 to-fuchsia-500',
  like_count integer not null default 0,
  view_count integer not null default 0,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours'
);
create index idx_stories_active on public.stories (expires_at desc);
grant select on public.stories to anon;
grant select, insert, update, delete on public.stories to authenticated;
grant all on public.stories to service_role;
alter table public.stories enable row level security;
create policy "stories_read_active" on public.stories for select using (expires_at > now());
create policy "stories_insert_self" on public.stories for insert to authenticated with check (author_id = auth.uid());
create policy "stories_delete_own_or_staff" on public.stories for delete to authenticated
  using (author_id = auth.uid() or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'moderator'));

create table public.story_likes (
  user_id uuid not null references public.profiles(id) on delete cascade,
  story_id uuid not null references public.stories(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, story_id)
);
grant select, insert, delete on public.story_likes to authenticated;
grant all on public.story_likes to service_role;
alter table public.story_likes enable row level security;
create policy "story_likes_read" on public.story_likes for select to authenticated using (true);
create policy "story_likes_write_self" on public.story_likes for insert to authenticated with check (user_id = auth.uid());
create policy "story_likes_delete_self" on public.story_likes for delete to authenticated using (user_id = auth.uid());

create or replace function public.story_likes_count_sync()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then update public.stories set like_count = like_count + 1 where id = new.story_id;
  else update public.stories set like_count = greatest(like_count - 1, 0) where id = old.story_id; end if;
  return null;
end $$;
revoke execute on function public.story_likes_count_sync() from public;
create trigger story_likes_count_sync after insert or delete on public.story_likes
  for each row execute function public.story_likes_count_sync();

-- ============ spaces ============
create table public.spaces (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  topic text not null default 'general',
  description text not null default '',
  gradient text not null default 'from-violet-500 to-fuchsia-500',
  live boolean not null default true,
  scheduled_for timestamptz,
  listener_count integer not null default 0,
  created_at timestamptz not null default now(),
  ended_at timestamptz
);
create index idx_spaces_live on public.spaces (live, created_at desc);
grant select on public.spaces to anon;
grant select, insert, update, delete on public.spaces to authenticated;
grant all on public.spaces to service_role;
alter table public.spaces enable row level security;
create policy "spaces_public_read" on public.spaces for select using (true);
create policy "spaces_insert_self" on public.spaces for insert to authenticated with check (host_id = auth.uid());
create policy "spaces_update_host_or_staff" on public.spaces for update to authenticated
  using (host_id = auth.uid() or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'moderator'))
  with check (true);
create policy "spaces_delete_host_or_staff" on public.spaces for delete to authenticated
  using (host_id = auth.uid() or public.has_role(auth.uid(),'admin'));

create table public.space_participants (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'listener' check (role in ('host','speaker','listener')),
  hand_raised boolean not null default false,
  is_muted boolean not null default true,
  is_speaking boolean not null default false,
  joined_at timestamptz not null default now(),
  unique (space_id, user_id)
);
create index idx_space_participants_space on public.space_participants (space_id);
grant select on public.space_participants to anon;
grant select, insert, update, delete on public.space_participants to authenticated;
grant all on public.space_participants to service_role;
alter table public.space_participants enable row level security;
create policy "space_participants_read" on public.space_participants for select using (true);
create policy "space_participants_join_self" on public.space_participants for insert to authenticated with check (user_id = auth.uid());
create policy "space_participants_update" on public.space_participants for update to authenticated
  using (user_id = auth.uid() or exists (select 1 from public.spaces s where s.id = space_id and s.host_id = auth.uid()))
  with check (true);
create policy "space_participants_leave" on public.space_participants for delete to authenticated
  using (user_id = auth.uid() or exists (select 1 from public.spaces s where s.id = space_id and s.host_id = auth.uid()));

create table public.space_messages (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now()
);
create index idx_space_messages_space on public.space_messages (space_id, created_at);
grant select on public.space_messages to anon;
grant select, insert, delete on public.space_messages to authenticated;
grant all on public.space_messages to service_role;
alter table public.space_messages enable row level security;
create policy "space_messages_read" on public.space_messages for select using (true);
create policy "space_messages_insert_self" on public.space_messages for insert to authenticated with check (user_id = auth.uid());
create policy "space_messages_delete_own_or_staff" on public.space_messages for delete to authenticated
  using (user_id = auth.uid() or public.has_role(auth.uid(),'moderator') or public.has_role(auth.uid(),'admin'));

create or replace function public.space_listeners_sync()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then update public.spaces set listener_count = listener_count + 1 where id = new.space_id;
  else update public.spaces set listener_count = greatest(listener_count - 1, 0) where id = old.space_id; end if;
  return null;
end $$;
revoke execute on function public.space_listeners_sync() from public;
create trigger space_listeners_sync after insert or delete on public.space_participants
  for each row execute function public.space_listeners_sync();

-- ============ direct messages ============
create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  user_a uuid not null references public.profiles(id) on delete cascade,
  user_b uuid not null references public.profiles(id) on delete cascade,
  last_message text not null default '',
  last_message_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (user_a < user_b),
  unique (user_a, user_b)
);
create index idx_conversations_users on public.conversations (user_a, user_b);
grant select, insert, update on public.conversations to authenticated;
grant all on public.conversations to service_role;
alter table public.conversations enable row level security;
create policy "conversations_participants" on public.conversations for select to authenticated
  using (auth.uid() in (user_a, user_b));
create policy "conversations_create" on public.conversations for insert to authenticated
  with check (auth.uid() in (user_a, user_b));
create policy "conversations_update" on public.conversations for update to authenticated
  using (auth.uid() in (user_a, user_b)) with check (auth.uid() in (user_a, user_b));

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text not null default '',
  media_url text,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index idx_messages_conversation on public.messages (conversation_id, created_at);
grant select, insert, update on public.messages to authenticated;
grant all on public.messages to service_role;
alter table public.messages enable row level security;
create policy "messages_read_participants" on public.messages for select to authenticated
  using (exists (select 1 from public.conversations c where c.id = conversation_id and auth.uid() in (c.user_a, c.user_b)));
create policy "messages_insert_participants" on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and exists (select 1 from public.conversations c where c.id = conversation_id and auth.uid() in (c.user_a, c.user_b)));
create policy "messages_update_participants" on public.messages for update to authenticated
  using (exists (select 1 from public.conversations c where c.id = conversation_id and auth.uid() in (c.user_a, c.user_b)))
  with check (true);

-- ============ feed personalisation ============
create table public.feed_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  topic_weights jsonb not null default '{}'::jsonb,
  muted_words text[] not null default '{}',
  show_reposts boolean not null default true,
  show_sensitive boolean not null default false,
  algorithm text not null default 'balanced' check (algorithm in ('balanced','recent','popular')),
  updated_at timestamptz not null default now()
);
grant select, insert, update on public.feed_preferences to authenticated;
grant all on public.feed_preferences to service_role;
alter table public.feed_preferences enable row level security;
create policy "feed_preferences_own" on public.feed_preferences for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create table public.feed_feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  post_id uuid references public.posts(id) on delete cascade,
  signal text not null check (signal in ('more','less','hide','report')),
  tag text,
  created_at timestamptz not null default now()
);
create index idx_feed_feedback_user on public.feed_feedback (user_id, created_at desc);
grant select, insert, delete on public.feed_feedback to authenticated;
grant all on public.feed_feedback to service_role;
alter table public.feed_feedback enable row level security;
create policy "feed_feedback_own" on public.feed_feedback for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create table public.post_views (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
grant select, insert on public.post_views to authenticated;
grant all on public.post_views to service_role;
alter table public.post_views enable row level security;
create policy "post_views_insert_self" on public.post_views for insert to authenticated with check (user_id = auth.uid());
create policy "post_views_read_self" on public.post_views for select to authenticated using (user_id = auth.uid());

create or replace function public.post_views_count_sync()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.posts set view_count = view_count + 1 where id = new.post_id;
  return null;
end $$;
revoke execute on function public.post_views_count_sync() from public;
create trigger post_views_count_sync after insert on public.post_views
  for each row execute function public.post_views_count_sync();

-- ============ moderation ============
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles(id) on delete set null,
  target_type text not null check (target_type in ('post','profile','space','message','story')),
  target_id uuid,
  reason text not null,
  details text not null default '',
  status text not null default 'open' check (status in ('open','reviewing','resolved','dismissed')),
  reviewer_id uuid references public.profiles(id) on delete set null,
  reviewer_notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_reports_status on public.reports (status, created_at desc);
grant select, insert, update on public.reports to authenticated;
grant all on public.reports to service_role;
alter table public.reports enable row level security;
create policy "reports_insert_self" on public.reports for insert to authenticated with check (reporter_id = auth.uid());
create policy "reports_read_own_or_staff" on public.reports for select to authenticated
  using (reporter_id = auth.uid() or public.has_role(auth.uid(),'moderator') or public.has_role(auth.uid(),'admin'));
create policy "reports_update_staff" on public.reports for update to authenticated
  using (public.has_role(auth.uid(),'moderator') or public.has_role(auth.uid(),'admin')) with check (true);
create trigger reports_updated_at before update on public.reports for each row execute function public.set_updated_at();

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles(id) on delete set null,
  action text not null,
  target_type text not null default '',
  target_id text not null default '',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index idx_audit_logs_created on public.audit_logs (created_at desc);
grant select, insert on public.audit_logs to authenticated;
grant all on public.audit_logs to service_role;
alter table public.audit_logs enable row level security;
create policy "audit_logs_read_staff" on public.audit_logs for select to authenticated
  using (public.has_role(auth.uid(),'moderator') or public.has_role(auth.uid(),'admin'));
create policy "audit_logs_insert_staff" on public.audit_logs for insert to authenticated
  with check (actor_id = auth.uid() and (public.has_role(auth.uid(),'moderator') or public.has_role(auth.uid(),'admin')));

create table public.system_settings (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
grant select on public.system_settings to anon, authenticated;
grant insert, update on public.system_settings to authenticated;
grant all on public.system_settings to service_role;
alter table public.system_settings enable row level security;
create policy "system_settings_read" on public.system_settings for select using (true);
create policy "system_settings_write_admin" on public.system_settings for all to authenticated
  using (public.has_role(auth.uid(),'admin')) with check (public.has_role(auth.uid(),'admin'));

insert into public.system_settings (key, value) values
  ('platform', '{"signupsOpen": true, "maintenanceMode": false, "aiFeatures": true, "spacesEnabled": true, "storiesEnabled": true, "announcement": ""}'::jsonb);

-- ============ billing & money ============
create table public.subscriptions (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  plan text not null default 'free' check (plan in ('free','plus','pro','team')),
  status text not null default 'active' check (status in ('active','canceled','past_due')),
  renews_at timestamptz,
  canceled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
grant select, insert, update on public.subscriptions to authenticated;
grant all on public.subscriptions to service_role;
alter table public.subscriptions enable row level security;
create policy "subscriptions_own_or_staff" on public.subscriptions for select to authenticated
  using (user_id = auth.uid() or public.has_role(auth.uid(),'admin'));
create policy "subscriptions_write_own" on public.subscriptions for insert to authenticated with check (user_id = auth.uid());
create policy "subscriptions_update_own" on public.subscriptions for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create trigger subscriptions_updated_at before update on public.subscriptions for each row execute function public.set_updated_at();

create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  plan text not null,
  amount numeric(10,2) not null default 0,
  currency text not null default 'USD',
  status text not null default 'paid' check (status in ('paid','open','void')),
  created_at timestamptz not null default now()
);
create index idx_invoices_user on public.invoices (user_id, created_at desc);
grant select, insert on public.invoices to authenticated;
grant all on public.invoices to service_role;
alter table public.invoices enable row level security;
create policy "invoices_own" on public.invoices for select to authenticated using (user_id = auth.uid());
create policy "invoices_insert_own" on public.invoices for insert to authenticated with check (user_id = auth.uid());

create table public.tips (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  amount numeric(10,2) not null check (amount > 0),
  message text not null default '',
  post_id uuid references public.posts(id) on delete set null,
  space_id uuid references public.spaces(id) on delete set null,
  created_at timestamptz not null default now()
);
create index idx_tips_recipient on public.tips (recipient_id, created_at desc);
grant select, insert on public.tips to authenticated;
grant all on public.tips to service_role;
alter table public.tips enable row level security;
create policy "tips_read_involved" on public.tips for select to authenticated
  using (auth.uid() in (sender_id, recipient_id) or public.has_role(auth.uid(),'admin'));
create policy "tips_insert_sender" on public.tips for insert to authenticated with check (sender_id = auth.uid());

create table public.payouts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount numeric(10,2) not null check (amount > 0),
  method text not null default 'bank',
  status text not null default 'pending' check (status in ('pending','processing','completed','failed')),
  created_at timestamptz not null default now()
);
create index idx_payouts_user on public.payouts (user_id, created_at desc);
grant select, insert on public.payouts to authenticated;
grant all on public.payouts to service_role;
alter table public.payouts enable row level security;
create policy "payouts_own" on public.payouts for select to authenticated
  using (user_id = auth.uid() or public.has_role(auth.uid(),'admin'));
create policy "payouts_insert_own" on public.payouts for insert to authenticated with check (user_id = auth.uid());

-- ============ developer platform ============
create table public.api_keys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  prefix text not null,
  key_hash text not null,
  scopes text[] not null default '{read}',
  last_used_at timestamptz,
  revoked boolean not null default false,
  created_at timestamptz not null default now()
);
create index idx_api_keys_user on public.api_keys (user_id, created_at desc);
grant select, insert, update, delete on public.api_keys to authenticated;
grant all on public.api_keys to service_role;
alter table public.api_keys enable row level security;
create policy "api_keys_own" on public.api_keys for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create table public.webhooks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  url text not null,
  events text[] not null default '{post.created}',
  active boolean not null default true,
  secret text not null,
  created_at timestamptz not null default now()
);
grant select, insert, update, delete on public.webhooks to authenticated;
grant all on public.webhooks to service_role;
alter table public.webhooks enable row level security;
create policy "webhooks_own" on public.webhooks for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ============ workspaces ============
create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  plan text not null default 'team',
  created_at timestamptz not null default now()
);
grant select, insert, update, delete on public.workspaces to authenticated;
grant all on public.workspaces to service_role;
alter table public.workspaces enable row level security;

create table public.workspace_members (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','admin','member','viewer')),
  created_at timestamptz not null default now(),
  unique (workspace_id, user_id)
);
grant select, insert, update, delete on public.workspace_members to authenticated;
grant all on public.workspace_members to service_role;
alter table public.workspace_members enable row level security;

create or replace function public.is_workspace_member(_workspace_id uuid, _user_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.workspace_members where workspace_id = _workspace_id and user_id = _user_id
  ) or exists (
    select 1 from public.workspaces where id = _workspace_id and owner_id = _user_id
  )
$$;
revoke execute on function public.is_workspace_member(uuid, uuid) from public;
grant execute on function public.is_workspace_member(uuid, uuid) to authenticated;

create policy "workspaces_member_read" on public.workspaces for select to authenticated
  using (public.is_workspace_member(id, auth.uid()));
create policy "workspaces_owner_write" on public.workspaces for insert to authenticated with check (owner_id = auth.uid());
create policy "workspaces_owner_update" on public.workspaces for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "workspaces_owner_delete" on public.workspaces for delete to authenticated using (owner_id = auth.uid());

create policy "workspace_members_read" on public.workspace_members for select to authenticated
  using (public.is_workspace_member(workspace_id, auth.uid()));
create policy "workspace_members_owner_write" on public.workspace_members for all to authenticated
  using (exists (select 1 from public.workspaces w where w.id = workspace_id and w.owner_id = auth.uid()))
  with check (exists (select 1 from public.workspaces w where w.id = workspace_id and w.owner_id = auth.uid()));

-- ============ support & branding ============
create table public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  subject text not null,
  body text not null default '',
  priority text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  status text not null default 'open' check (status in ('open','pending','resolved','closed')),
  response text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_support_tickets_user on public.support_tickets (user_id, created_at desc);
grant select, insert, update on public.support_tickets to authenticated;
grant all on public.support_tickets to service_role;
alter table public.support_tickets enable row level security;
create policy "support_tickets_own_or_staff" on public.support_tickets for select to authenticated
  using (user_id = auth.uid() or public.has_role(auth.uid(),'admin'));
create policy "support_tickets_insert_own" on public.support_tickets for insert to authenticated with check (user_id = auth.uid());
create policy "support_tickets_update_own_or_staff" on public.support_tickets for update to authenticated
  using (user_id = auth.uid() or public.has_role(auth.uid(),'admin')) with check (true);
create trigger support_tickets_updated_at before update on public.support_tickets for each row execute function public.set_updated_at();

create table public.branding_settings (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  accent_color text not null default 'violet',
  logo_url text,
  custom_domain text,
  hide_platform_badge boolean not null default false,
  updated_at timestamptz not null default now()
);
grant select, insert, update on public.branding_settings to authenticated;
grant all on public.branding_settings to service_role;
alter table public.branding_settings enable row level security;
create policy "branding_own" on public.branding_settings for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create trigger branding_updated_at before update on public.branding_settings for each row execute function public.set_updated_at();

-- ============ realtime ============
alter publication supabase_realtime add table public.posts;
alter publication supabase_realtime add table public.messages;
alter publication supabase_realtime add table public.conversations;
alter publication supabase_realtime add table public.notifications;
alter publication supabase_realtime add table public.space_messages;
alter publication supabase_realtime add table public.space_participants;
alter publication supabase_realtime add table public.spaces;

-- ============ demo live spaces ============
insert into public.spaces (id, host_id, title, topic, description, gradient, live, listener_count) values
  ('bbbbbbb1-0000-4000-8000-000000000001','22222222-2222-4222-8222-222222222222','Shooting golden hour on vintage glass','photography','Lens tests, flare and forty-year-old character.','from-orange-400 via-rose-400 to-violet-500',true,0),
  ('bbbbbbb1-0000-4000-8000-000000000002','33333333-3333-4333-8333-333333333333','Latency, presence and spatial UI','technology','Where spatial interfaces break and why.','from-sky-400 via-cyan-400 to-emerald-400',true,0);