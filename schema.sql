-- DealBasis database schema for Supabase.
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste this file -> Run.
-- Safe to run again: every statement checks before it creates.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- Who belongs to this workspace. The first person to sign in becomes its admin.
create table if not exists public.members (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  email      text,
  role       text not null default 'member' check (role in ('admin', 'member', 'viewer')),
  created_at timestamptz not null default now()
);

-- Emails an admin has invited. An invited person joins with this role when they first sign in.
create table if not exists public.invites (
  email      text primary key,
  role       text not null default 'member' check (role in ('admin', 'member', 'viewer')),
  invited_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

-- Workspace settings (one row). allowed_domain lets anyone with a confirmed email at that domain join as a member.
create table if not exists public.settings (
  id             int primary key default 1 check (id = 1),
  workspace_name text not null default 'DealBasis',
  allowed_domain text,
  owner_email    text
);
alter table public.settings add column if not exists owner_email text;
insert into public.settings (id) values (1) on conflict (id) do nothing;
-- Recommended: only this email can become the first admin. Replace with your own email before running,
-- or leave it as is and the first person to sign up becomes the admin.
-- update public.settings set owner_email = 'you@yourfirm.com' where id = 1;

-- People an admin removed (No access). They cannot rejoin through an invite or the allowed domain until an admin restores them.
create table if not exists public.blocked (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  blocked_at timestamptz not null default now()
);

-- Display names, so activity and comments show who did what.
create table if not exists public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  email      text,
  name       text,
  avatar_url text
);

-- Every record the app keeps: deals, firm settings, team roles, people. Keyed by path, e.g. 'deals/abc123'.
create table if not exists public.kv (
  path       text primary key,
  collection text not null,
  data       jsonb not null,
  updated_by uuid,
  updated_at timestamptz not null default now()
);
create index if not exists kv_collection_idx on public.kv (collection);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- The signed-in person's role in this workspace, or null when they are not a member.
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.members where user_id = auth.uid()
$$;

-- Who may write a record. Firm settings and team roles: admins. A person's own presence record: that person.
-- Deals: admins and members. Viewers never write.
create or replace function public.can_write(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when public.my_role() is null or public.my_role() = 'viewer' then false
    when p like 'team/%' or p like 'firm/%' then public.my_role() = 'admin'
    when p like 'people/%' then public.my_role() = 'admin' or p = 'people/' || auth.uid()::text
    else true
  end
$$;

-- Called by the app after every sign-in. Records the profile and returns the person's role,
-- adding them to the workspace when they are the first person, invited, or at the allowed domain.
-- Returns 'none' when they have no access, and 'unconfirmed' when their email is not confirmed yet.
create or replace function public.join_workspace() returns text
language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := auth.uid();
  em   text;
  nm   text;
  conf timestamptz;
  r    text;
  dom  text;
begin
  if uid is null then return 'none'; end if;
  select u.email,
         coalesce(nullif(u.raw_user_meta_data ->> 'full_name', ''), nullif(u.raw_user_meta_data ->> 'name', ''), split_part(u.email, '@', 1)),
         u.email_confirmed_at
    into em, nm, conf
    from auth.users u where u.id = uid;

  insert into public.profiles (id, email, name) values (uid, em, nm)
    on conflict (id) do update set email = excluded.email, name = coalesce(nullif(public.profiles.name, ''), excluded.name);

  select m.role into r from public.members m where m.user_id = uid;
  if r is not null then return r; end if;

  -- joining needs a confirmed email, so nobody can claim an address they do not control
  if conf is null then return 'unconfirmed'; end if;

  perform pg_advisory_xact_lock(724501);
  if not exists (select 1 from public.members) then
    select s.owner_email into dom from public.settings s where s.id = 1;
    if coalesce(dom, '') = '' or lower(dom) = lower(em) then
      insert into public.members (user_id, email, role) values (uid, em, 'admin');
      return 'admin';
    end if;
    dom := null;
  end if;

  select i.role into r from public.invites i where lower(i.email) = lower(em);
  if r is not null then
    delete from public.blocked where user_id = uid;   -- an explicit invite restores someone who was removed
  elsif exists (select 1 from public.blocked b where b.user_id = uid) then
    return 'none';
  else
    select s.allowed_domain into dom from public.settings s where s.id = 1;
    if coalesce(dom, '') <> '' and lower(split_part(em, '@', 2)) = lower(trim(both '@' from dom)) then r := 'member'; end if;
  end if;
  if r is null then return 'none'; end if;

  insert into public.members (user_id, email, role) values (uid, em, r);
  delete from public.invites where lower(email) = lower(em);
  return r;
end
$$;

-- When an admin sets someone to Viewer or No access on the Team & Access page, the database follows:
-- Viewer can no longer write, and No access removes them from the workspace. Admins are changed only on the admin page.
create or replace function public.sync_team_role() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  uid uuid;
  r   text;
begin
  if new.collection <> 'team' then return new; end if;
  begin uid := split_part(new.path, '/', 2)::uuid; exception when others then return new; end;
  r := new.data ->> 'role';
  if r = 'removed' then
    if exists (select 1 from public.members where user_id = uid and role = 'admin') then return new; end if;
    delete from public.members where user_id = uid;
    insert into public.blocked (user_id) values (uid) on conflict (user_id) do nothing;
  else
    -- restored or changed: lift any block and give the matching access
    delete from public.blocked where user_id = uid;
    if exists (select 1 from auth.users where id = uid) then
      insert into public.members (user_id, email, role)
        select uid, u.email, case when r = 'viewer' then 'viewer' else 'member' end from auth.users u where u.id = uid
        on conflict (user_id) do update set role = case when public.members.role = 'admin' then 'admin' when r = 'viewer' then 'viewer' else 'member' end;
    end if;
  end if;
  return new;
end
$$;
drop trigger if exists kv_team_role on public.kv;
create trigger kv_team_role after insert or update on public.kv
  for each row execute function public.sync_team_role();

-- ---------------------------------------------------------------------------
-- Access rules (row-level security)
-- ---------------------------------------------------------------------------

alter table public.members  enable row level security;
alter table public.invites  enable row level security;
alter table public.settings enable row level security;
alter table public.profiles enable row level security;
alter table public.kv       enable row level security;
alter table public.blocked  enable row level security;

drop policy if exists blocked_admin on public.blocked;
create policy blocked_admin on public.blocked for all using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

drop policy if exists kv_read on public.kv;
drop policy if exists kv_insert on public.kv;
drop policy if exists kv_update on public.kv;
drop policy if exists kv_delete on public.kv;
create policy kv_read   on public.kv for select using (public.my_role() is not null);
create policy kv_insert on public.kv for insert with check (public.can_write(path) and collection = regexp_replace(path, '/[^/]+$', ''));
create policy kv_update on public.kv for update using (public.can_write(path)) with check (public.can_write(path) and collection = regexp_replace(path, '/[^/]+$', ''));
create policy kv_delete on public.kv for delete using (public.can_write(path));

drop policy if exists members_read on public.members;
drop policy if exists members_admin_update on public.members;
drop policy if exists members_admin_delete on public.members;
create policy members_read         on public.members for select using (public.my_role() is not null);
create policy members_admin_update on public.members for update using (public.my_role() = 'admin') with check (public.my_role() = 'admin');
create policy members_admin_delete on public.members for delete using (public.my_role() = 'admin' and user_id <> auth.uid());

drop policy if exists invites_admin on public.invites;
create policy invites_admin on public.invites for all using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

drop policy if exists settings_read on public.settings;
drop policy if exists settings_admin on public.settings;
create policy settings_read  on public.settings for select using (public.my_role() is not null);
create policy settings_admin on public.settings for update using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

drop policy if exists profiles_read on public.profiles;
drop policy if exists profiles_self on public.profiles;
create policy profiles_read on public.profiles for select using (public.my_role() is not null or id = auth.uid());
create policy profiles_self on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

grant usage on schema public to authenticated;
grant select, insert, update, delete on public.kv to authenticated;
grant select, update, delete on public.members to authenticated;
grant select, insert, update, delete on public.invites to authenticated;
grant select, insert, delete on public.blocked to authenticated;
grant select, update on public.settings to authenticated;
grant select, update on public.profiles to authenticated;
grant execute on function public.my_role(), public.can_write(text), public.join_workspace() to authenticated;
revoke all on public.kv, public.members, public.invites, public.settings, public.profiles, public.blocked from anon;

-- ---------------------------------------------------------------------------
-- File storage: uploaded documents and their originals (private bucket, 50 MB per file)
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit)
values ('assets', 'assets', false, 52428800)
on conflict (id) do nothing;

drop policy if exists dealbasis_assets_read on storage.objects;
drop policy if exists dealbasis_assets_insert on storage.objects;
drop policy if exists dealbasis_assets_delete on storage.objects;
create policy dealbasis_assets_read   on storage.objects for select using (bucket_id = 'assets' and public.my_role() is not null);
create policy dealbasis_assets_insert on storage.objects for insert with check (bucket_id = 'assets' and public.my_role() in ('admin', 'member'));
create policy dealbasis_assets_delete on storage.objects for delete using (bucket_id = 'assets' and public.my_role() in ('admin', 'member'));

-- ---------------------------------------------------------------------------
-- Live updates: everyone in the workspace sees saved changes without reloading
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'kv') then
    alter publication supabase_realtime add table public.kv;
  end if;
end
$$;
