-- ============ enums & helpers ============
create type public.app_role as enum ('admin', 'moderator', 'user');

create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at = now(); return new; end $$;

-- ============ profiles ============
create table public.profiles (
  id uuid primary key default gen_random_uuid(),
  username text not null unique,
  display_name text not null,
  bio text not null default '',
  avatar_url text,
  banner_url text,
  location text not null default '',
  website text not null default '',
  verified boolean not null default false,
  follower_count integer not null default 0,
  following_count integer not null default 0,
  post_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_profiles_username on public.profiles (lower(username));

grant select on public.profiles to anon;
grant select, insert, update on public.profiles to authenticated;
grant all on public.profiles to service_role;
alter table public.profiles enable row level security;
create policy "profiles_public_read" on public.profiles for select using (true);
create policy "profiles_insert_self" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "profiles_update_self" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create trigger profiles_updated_at before update on public.profiles for each row execute function public.set_updated_at();

-- ============ roles ============
create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  role public.app_role not null,
  created_at timestamptz not null default now(),
  unique (user_id, role)
);
grant select on public.user_roles to authenticated;
grant all on public.user_roles to service_role;
alter table public.user_roles enable row level security;

create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _user_id and role = _role)
$$;

create policy "user_roles_read_self" on public.user_roles for select to authenticated
  using (user_id = auth.uid() or public.has_role(auth.uid(), 'admin'));

-- ============ new user bootstrap ============
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare base_username text; final_username text; suffix integer := 0;
begin
  base_username := regexp_replace(
    coalesce(new.raw_user_meta_data->>'username', split_part(coalesce(new.email, 'member'), '@', 1)),
    '[^a-zA-Z0-9_]', '', 'g');
  if base_username = '' then base_username := 'member'; end if;
  final_username := lower(base_username);
  while exists (select 1 from public.profiles where lower(username) = final_username) loop
    suffix := suffix + 1;
    final_username := lower(base_username) || suffix::text;
  end loop;

  insert into public.profiles (id, username, display_name, avatar_url, bio)
  values (
    new.id,
    final_username,
    coalesce(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'full_name', base_username),
    new.raw_user_meta_data->>'avatar_url',
    coalesce(new.raw_user_meta_data->>'bio', '')
  ) on conflict (id) do nothing;

  insert into public.user_roles (user_id, role) values (new.id, 'user') on conflict do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============ posts ============
create table public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  parent_id uuid references public.posts(id) on delete cascade,
  content text not null,
  media_url text,
  gradient text,
  tags text[] not null default '{}',
  poll jsonb,
  visibility text not null default 'public' check (visibility in ('public','followers')),
  like_count integer not null default 0,
  comment_count integer not null default 0,
  repost_count integer not null default 0,
  view_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_posts_created_at on public.posts (created_at desc);
create index idx_posts_author on public.posts (author_id, created_at desc);
create index idx_posts_parent on public.posts (parent_id, created_at);
create index idx_posts_tags on public.posts using gin (tags);

grant select on public.posts to anon;
grant select, insert, update, delete on public.posts to authenticated;
grant all on public.posts to service_role;
alter table public.posts enable row level security;
create policy "posts_public_read" on public.posts for select using (true);
create policy "posts_insert_self" on public.posts for insert to authenticated with check (author_id = auth.uid());
create policy "posts_update_own" on public.posts for update to authenticated using (author_id = auth.uid()) with check (author_id = auth.uid());
create policy "posts_delete_own_or_staff" on public.posts for delete to authenticated
  using (author_id = auth.uid() or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'moderator'));
create trigger posts_updated_at before update on public.posts for each row execute function public.set_updated_at();

-- author post counter + reply counter
create or replace function public.posts_counts_sync()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.parent_id is null then
      update public.profiles set post_count = post_count + 1 where id = new.author_id;
    else
      update public.posts set comment_count = comment_count + 1 where id = new.parent_id;
    end if;
  elsif tg_op = 'DELETE' then
    if old.parent_id is null then
      update public.profiles set post_count = greatest(post_count - 1, 0) where id = old.author_id;
    else
      update public.posts set comment_count = greatest(comment_count - 1, 0) where id = old.parent_id;
    end if;
  end if;
  return null;
end $$;
create trigger posts_counts_sync after insert or delete on public.posts
  for each row execute function public.posts_counts_sync();

-- ============ interactions ============
create table public.likes (
  user_id uuid not null references public.profiles(id) on delete cascade,
  post_id uuid not null references public.posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);
create index idx_likes_post on public.likes (post_id);
grant select on public.likes to anon;
grant select, insert, delete on public.likes to authenticated;
grant all on public.likes to service_role;
alter table public.likes enable row level security;
create policy "likes_public_read" on public.likes for select using (true);
create policy "likes_write_self" on public.likes for insert to authenticated with check (user_id = auth.uid());
create policy "likes_delete_self" on public.likes for delete to authenticated using (user_id = auth.uid());

create table public.reposts (
  user_id uuid not null references public.profiles(id) on delete cascade,
  post_id uuid not null references public.posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);
create index idx_reposts_post on public.reposts (post_id);
grant select on public.reposts to anon;
grant select, insert, delete on public.reposts to authenticated;
grant all on public.reposts to service_role;
alter table public.reposts enable row level security;
create policy "reposts_public_read" on public.reposts for select using (true);
create policy "reposts_write_self" on public.reposts for insert to authenticated with check (user_id = auth.uid());
create policy "reposts_delete_self" on public.reposts for delete to authenticated using (user_id = auth.uid());

create table public.bookmarks (
  user_id uuid not null references public.profiles(id) on delete cascade,
  post_id uuid not null references public.posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);
grant select, insert, delete on public.bookmarks to authenticated;
grant all on public.bookmarks to service_role;
alter table public.bookmarks enable row level security;
create policy "bookmarks_own" on public.bookmarks for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create table public.follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  target_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, target_id),
  check (follower_id <> target_id)
);
create index idx_follows_target on public.follows (target_id);
grant select on public.follows to anon;
grant select, insert, delete on public.follows to authenticated;
grant all on public.follows to service_role;
alter table public.follows enable row level security;
create policy "follows_public_read" on public.follows for select using (true);
create policy "follows_write_self" on public.follows for insert to authenticated with check (follower_id = auth.uid());
create policy "follows_delete_self" on public.follows for delete to authenticated using (follower_id = auth.uid());

create or replace function public.likes_count_sync()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then update public.posts set like_count = like_count + 1 where id = new.post_id;
  else update public.posts set like_count = greatest(like_count - 1, 0) where id = old.post_id; end if;
  return null;
end $$;
create trigger likes_count_sync after insert or delete on public.likes
  for each row execute function public.likes_count_sync();

create or replace function public.reposts_count_sync()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then update public.posts set repost_count = repost_count + 1 where id = new.post_id;
  else update public.posts set repost_count = greatest(repost_count - 1, 0) where id = old.post_id; end if;
  return null;
end $$;
create trigger reposts_count_sync after insert or delete on public.reposts
  for each row execute function public.reposts_count_sync();

create or replace function public.follows_count_sync()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.profiles set following_count = following_count + 1 where id = new.follower_id;
    update public.profiles set follower_count = follower_count + 1 where id = new.target_id;
  else
    update public.profiles set following_count = greatest(following_count - 1, 0) where id = old.follower_id;
    update public.profiles set follower_count = greatest(follower_count - 1, 0) where id = old.target_id;
  end if;
  return null;
end $$;
create trigger follows_count_sync after insert or delete on public.follows
  for each row execute function public.follows_count_sync();

-- ============ notifications ============
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete cascade,
  type text not null check (type in ('like','repost','comment','follow','mention','space','tip','system')),
  body text not null default '',
  entity_id uuid,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index idx_notifications_recipient on public.notifications (recipient_id, created_at desc);
grant select, insert, update, delete on public.notifications to authenticated;
grant all on public.notifications to service_role;
alter table public.notifications enable row level security;
create policy "notifications_read_own" on public.notifications for select to authenticated using (recipient_id = auth.uid());
create policy "notifications_update_own" on public.notifications for update to authenticated using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());
create policy "notifications_delete_own" on public.notifications for delete to authenticated using (recipient_id = auth.uid());
create policy "notifications_insert_as_actor" on public.notifications for insert to authenticated with check (actor_id = auth.uid());

-- ============ topics ============
create table public.topics (
  slug text primary key,
  name text not null,
  gradient text not null default 'from-violet-500 to-fuchsia-500',
  description text not null default ''
);
grant select on public.topics to anon, authenticated;
grant all on public.topics to service_role;
alter table public.topics enable row level security;
create policy "topics_public_read" on public.topics for select using (true);

insert into public.topics (slug, name, gradient, description) values
  ('design','Design','from-violet-500 to-fuchsia-500','Interfaces, type and craft'),
  ('photography','Photography','from-orange-500 to-rose-500','Light, lenses and long exposures'),
  ('technology','Technology','from-sky-500 to-cyan-500','Hardware, software and the future'),
  ('audio','Audio','from-emerald-500 to-teal-500','Field recordings and sound design'),
  ('writing','Writing','from-amber-500 to-orange-500','Essays, drafts and notebooks'),
  ('film','Film','from-indigo-500 to-violet-500','Frames, edits and storytelling');

-- ============ demo content ============
insert into public.profiles (id, username, display_name, bio, location, website, verified, follower_count, following_count) values
  ('11111111-1111-4111-8111-111111111111','clarawrites','Clara Meyer','Essays on attention, craft and the slow internet.','Berlin, DE','clara.ink',true,42310,512),
  ('22222222-2222-4222-8222-222222222222','marcusfilm','Marcus Bell','Cinematographer. Golden hour obsessive.','Los Angeles, US','marcus.film',true,88120,220),
  ('33333333-3333-4333-8333-333333333333','yuki','Yuki Tanaka','Spatial computing, tiny robots, big diagrams.','Tokyo, JP','yuki.dev',false,30470,190),
  ('44444444-4444-4444-8444-444444444444','diegom','Diego Marquez','Sound designer. Field recordings from everywhere.','Mexico City, MX','diego.audio',false,15600,640),
  ('55555555-5555-4555-8555-555555555555','priyas','Priya Sharma','Product engineer. Shipping small things daily.','Bengaluru, IN','priya.sh',true,21900,410);

insert into public.posts (id, author_id, content, gradient, tags, like_count, comment_count, repost_count, view_count, created_at) values
  ('aaaaaaa1-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111','Spent the morning rewriting one paragraph eleven times. The eleventh took forty seconds. The first ten were the price of admission.',null,'{writing,craft}',1284,0,212,48200, now() - interval '8 minutes'),
  ('aaaaaaa1-0000-4000-8000-000000000002','22222222-2222-4222-8222-222222222222','Shot this entirely on a forty-year-old lens. Every flaw in the glass became part of the frame.','from-orange-400 via-rose-400 to-violet-500','{goldenhour,photography}',5310,0,880,194000, now() - interval '42 minutes'),
  ('aaaaaaa1-0000-4000-8000-000000000003','33333333-3333-4333-8333-333333333333','Prototype note: spatial UI stops feeling like magic the moment latency crosses 90ms. After that it is physics you can feel.',null,'{spatialcomputing,technology}',2044,0,401,77400, now() - interval '2 hours'),
  ('aaaaaaa1-0000-4000-8000-000000000004','44444444-4444-4444-8444-444444444444','Recorded a thunderstorm from inside a parked car at 3am, pitched it down two octaves, and it became the calmest thing I own.','from-sky-400 via-cyan-400 to-emerald-400','{audio,fieldrecording}',932,0,143,28900, now() - interval '4 hours'),
  ('aaaaaaa1-0000-4000-8000-000000000005','55555555-5555-4555-8555-555555555555','Shipped a twelve-line change that removed a four-hundred-line abstraction. Best week of the quarter and nobody will notice.',null,'{engineering,technology}',3611,0,622,121000, now() - interval '7 hours');

insert into public.follows (follower_id, target_id) values
  ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222'),
  ('33333333-3333-4333-8333-333333333333','11111111-1111-4111-8111-111111111111'),
  ('55555555-5555-4555-8555-555555555555','33333333-3333-4333-8333-333333333333');