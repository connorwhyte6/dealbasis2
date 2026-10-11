-- DealBasis database schema for Supabase.
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste this whole file -> Run.
-- Safe to run again, and safe to run over the earlier single-workspace version: existing deals,
-- members and files move into one workspace automatically and nothing is deleted.
--
-- Every firm gets its own private workspace. Deals, files, invites and members of one workspace
-- can never be read or changed from another, and the database itself enforces it (row-level security),
-- not just the app.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- One row per firm. allowed_domain lets anyone with a confirmed email at that domain join it as a member.
create table if not exists public.workspaces (
  id             uuid primary key default gen_random_uuid(),
  name           text not null default 'My firm',
  allowed_domain text,
  legacy_files   boolean not null default false,  -- files uploaded before workspaces existed live at the top of the bucket
  created_by     uuid references auth.users (id) on delete set null,
  created_at     timestamptz not null default now()
);
create unique index if not exists workspaces_domain_key on public.workspaces (lower(allowed_domain)) where allowed_domain is not null;
-- personal email domains would let strangers into a firm, so they can't be a firm domain
alter table public.workspaces drop constraint if exists workspaces_domain_check;
alter table public.workspaces add constraint workspaces_domain_check check (
  allowed_domain is null or lower(allowed_domain) not in (
    'gmail.com','googlemail.com','outlook.com','hotmail.com','live.com','msn.com','yahoo.com','ymail.com','icloud.com','me.com','mac.com',
    'aol.com','proton.me','protonmail.com','pm.me','gmx.com','gmx.net','mail.com','zoho.com','yandex.com','hey.com','fastmail.com'));

alter table public.workspaces add column if not exists require_mfa boolean not null default false;   -- everyone must use two-factor sign-in
alter table public.workspaces add column if not exists idle_minutes int not null default 30;            -- sign out after this long without activity
alter table public.workspaces drop constraint if exists workspaces_idle_check;
alter table public.workspaces add constraint workspaces_idle_check check (idle_minutes between 5 and 480);

-- Who belongs to which workspace. Each person belongs to one workspace.
create table if not exists public.members (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  email      text,
  role       text not null default 'member' check (role in ('admin', 'member', 'viewer')),
  created_at timestamptz not null default now()
);

-- Emails an admin has invited. An invited person joins that workspace with this role when they first sign in.
create table if not exists public.invites (
  email      text not null,
  role       text not null default 'member' check (role in ('admin', 'member', 'viewer')),
  invited_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

-- People an admin removed (No access). They cannot rejoin that workspace through its domain until an admin restores or re-invites them.
create table if not exists public.blocked (
  user_id    uuid not null references auth.users (id) on delete cascade,
  blocked_at timestamptz not null default now()
);

-- Display names, so activity and comments show who did what.
create table if not exists public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  email      text,
  name       text,
  avatar_url text
);

-- Every record the app keeps: deals, firm settings, team roles, people. Keyed by workspace and path, e.g. 'deals/abc123'.
create table if not exists public.kv (
  path       text not null,
  collection text not null,
  data       jsonb not null,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

-- Left from the single-workspace version; read once below to carry its name and domain over, then unused.
create table if not exists public.settings (
  id             int primary key default 1 check (id = 1),
  workspace_name text not null default 'DealBasis',
  allowed_domain text,
  owner_email    text
);
alter table public.settings add column if not exists owner_email text;

-- every workspace-owned table carries its workspace
alter table public.members add column if not exists workspace_id uuid references public.workspaces (id) on delete cascade;
alter table public.invites add column if not exists workspace_id uuid references public.workspaces (id) on delete cascade;
alter table public.blocked add column if not exists workspace_id uuid references public.workspaces (id) on delete cascade;
alter table public.kv      add column if not exists workspace_id uuid references public.workspaces (id) on delete cascade;

-- ---------------------------------------------------------------------------
-- Move an existing single-workspace install into its own workspace
-- ---------------------------------------------------------------------------

do $$
declare w uuid;
begin
  if exists (select 1 from public.members where workspace_id is null) or exists (select 1 from public.kv where workspace_id is null)
     or exists (select 1 from public.invites where workspace_id is null) or exists (select 1 from public.blocked where workspace_id is null) then
    select id into w from public.workspaces where legacy_files order by created_at limit 1;
    if w is null then
      insert into public.workspaces (name, allowed_domain, legacy_files, created_by)
      values (
        coalesce((select nullif(s.workspace_name, '') from public.settings s where s.id = 1), 'DealBasis'),
        (select nullif(lower(trim(both '@' from coalesce(s.allowed_domain, ''))), '') from public.settings s where s.id = 1),
        true,
        (select m.user_id from public.members m where m.role = 'admin' order by m.created_at limit 1))
      returning id into w;
    end if;
    update public.members set workspace_id = w where workspace_id is null;
    update public.invites set workspace_id = w where workspace_id is null;
    update public.blocked set workspace_id = w where workspace_id is null;
    update public.kv      set workspace_id = w where workspace_id is null;
  end if;
end
$$;

alter table public.members alter column workspace_id set not null;
alter table public.invites alter column workspace_id set not null;
alter table public.blocked alter column workspace_id set not null;
alter table public.kv      alter column workspace_id set not null;

-- keys now include the workspace, so two firms can each have their own 'firm/settings' record
do $$
begin
  if not exists (select 1 from information_schema.key_column_usage k where k.table_schema = 'public' and k.table_name = 'kv' and k.constraint_name = 'kv_pkey' and k.column_name = 'workspace_id') then
    alter table public.kv drop constraint if exists kv_pkey;
    alter table public.kv add constraint kv_pkey primary key (workspace_id, path);
  end if;
  if not exists (select 1 from information_schema.key_column_usage k where k.table_schema = 'public' and k.table_name = 'invites' and k.constraint_name = 'invites_pkey' and k.column_name = 'workspace_id') then
    alter table public.invites drop constraint if exists invites_pkey;
    alter table public.invites add constraint invites_pkey primary key (workspace_id, email);
  end if;
  if not exists (select 1 from information_schema.key_column_usage k where k.table_schema = 'public' and k.table_name = 'blocked' and k.constraint_name = 'blocked_pkey' and k.column_name = 'workspace_id') then
    alter table public.blocked drop constraint if exists blocked_pkey;
    alter table public.blocked add constraint blocked_pkey primary key (workspace_id, user_id);
  end if;
end
$$;

drop index if exists public.kv_collection_idx;
create index if not exists kv_ws_collection_idx on public.kv (workspace_id, collection);
create index if not exists members_ws_idx on public.members (workspace_id);
create index if not exists invites_email_idx on public.invites (lower(email));

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- The signed-in person's workspace, or null when they are not in one.
-- Whether this sign-in passed two-factor (Supabase marks it 'aal2' in the session token).
create or replace function public.signed_in_with_mfa() returns boolean
language sql stable as $$
  select coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
$$;

-- The signed-in person's workspace, or null when they are not in one. When the workspace requires
-- two-factor sign-in and this session hasn't passed it, this is null too, so every rule below denies access.
create or replace function public.my_ws() returns uuid
language sql stable security definer set search_path = public as $$
  select m.workspace_id from public.members m join public.workspaces w on w.id = m.workspace_id
  where m.user_id = auth.uid() and (not w.require_mfa or public.signed_in_with_mfa())
$$;

-- The signed-in person's role in their workspace, or null when they are not a member.
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select m.role from public.members m join public.workspaces w on w.id = m.workspace_id
  where m.user_id = auth.uid() and (not w.require_mfa or public.signed_in_with_mfa())
$$;

-- The signed-in person's workspace, for the app: id, name, role and whether it has files from before workspaces.
create or replace function public.my_workspace() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('id', w.id, 'name', w.name, 'role', m.role, 'legacyFiles', w.legacy_files, 'allowedDomain', w.allowed_domain,
                           'requireMfa', w.require_mfa, 'idleMinutes', w.idle_minutes, 'mfa', public.signed_in_with_mfa())
  from public.members m join public.workspaces w on w.id = m.workspace_id
  where m.user_id = auth.uid()
$$;

-- new rows land in the writer's own workspace when the app doesn't say which
alter table public.kv      alter column workspace_id set default public.my_ws();
alter table public.invites alter column workspace_id set default public.my_ws();
alter table public.blocked alter column workspace_id set default public.my_ws();

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

-- Called by the app after every sign-in. Records the profile and returns the person's role.
-- Someone new joins the workspace that invited them, or the one whose firm domain matches their email;
-- otherwise they get a new private workspace of their own, as its admin.
-- Returns 'unconfirmed' when their email is not confirmed yet.
create or replace function public.join_workspace() returns text
language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := auth.uid();
  em   text;
  nm   text;
  conf timestamptz;
  r    text;
  ir   text;
  w    uuid;
  cur  uuid;
begin
  if uid is null then return 'none'; end if;
  select u.email,
         coalesce(nullif(u.raw_user_meta_data ->> 'full_name', ''), nullif(u.raw_user_meta_data ->> 'name', ''), split_part(u.email, '@', 1)),
         u.email_confirmed_at
    into em, nm, conf
    from auth.users u where u.id = uid;

  insert into public.profiles (id, email, name) values (uid, em, nm)
    on conflict (id) do update set email = excluded.email, name = coalesce(nullif(public.profiles.name, ''), excluded.name);

  select m.role, m.workspace_id into r, cur from public.members m where m.user_id = uid;
  if r is not null then
    -- someone who tried DealBasis on their own and is then invited by a firm moves into the firm,
    -- as long as their own workspace is still empty (no deals, no files, nobody else in it)
    if conf is not null then
      select i.workspace_id, i.role into w, ir from public.invites i
       where lower(i.email) = lower(em) and i.workspace_id <> cur order by i.created_at desc limit 1;
      if w is not null
         and not exists (select 1 from public.members m where m.workspace_id = cur and m.user_id <> uid)
         and not exists (select 1 from public.kv k where k.workspace_id = cur and k.collection like 'deals%')
         and not exists (select 1 from storage.objects o where o.bucket_id = 'assets' and split_part(o.name, '/', 1) = cur::text) then
        update public.members set workspace_id = w, role = ir where user_id = uid;
        delete from public.blocked where workspace_id = w and user_id = uid;
        delete from public.invites where lower(email) = lower(em) and workspace_id = w;
        delete from public.workspaces where id = cur and not exists (select 1 from public.members m where m.workspace_id = cur);
        return ir;
      end if;
    end if;
    return r;
  end if;

  -- joining needs a confirmed email, so nobody can claim an address they do not control
  if conf is null then return 'unconfirmed'; end if;

  perform pg_advisory_xact_lock(724501);
  select m.role into r from public.members m where m.user_id = uid;
  if r is not null then return r; end if;

  -- an invite wins (the newest, if several firms invited them); it also lifts an earlier removal
  select i.workspace_id, i.role into w, r from public.invites i where lower(i.email) = lower(em) order by i.created_at desc limit 1;
  if w is not null then
    delete from public.blocked where workspace_id = w and user_id = uid;
  else
    select ws.id into w from public.workspaces ws
     where ws.allowed_domain is not null and lower(ws.allowed_domain) = lower(split_part(em, '@', 2))
       and not exists (select 1 from public.blocked b where b.workspace_id = ws.id and b.user_id = uid);
    if w is not null then r := 'member'; end if;
  end if;

  if w is null then
    insert into public.workspaces (name, created_by) values (coalesce(nullif(nm, ''), 'My') || '''s workspace', uid) returning id into w;
    r := 'admin';
  end if;

  insert into public.members (user_id, email, role, workspace_id) values (uid, em, r, w);
  delete from public.invites where lower(email) = lower(em) and workspace_id = w;
  return r;
end
$$;

-- When an admin sets someone to Viewer or No access on the Team & Access page, the database follows:
-- Viewer can no longer write, and No access removes them from the workspace. Admins are changed only on the admin page.
-- It only ever touches people in, or removed from, the same workspace as the record.
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
    if not exists (select 1 from public.members where user_id = uid and workspace_id = new.workspace_id) then return new; end if;
    if exists (select 1 from public.members where user_id = uid and workspace_id = new.workspace_id and role = 'admin') then return new; end if;
    delete from public.members where user_id = uid and workspace_id = new.workspace_id;
    insert into public.blocked (workspace_id, user_id) values (new.workspace_id, uid) on conflict do nothing;
  elsif exists (select 1 from public.members where user_id = uid and workspace_id = new.workspace_id) then
    update public.members set role = case when r = 'viewer' then 'viewer' else 'member' end
     where user_id = uid and workspace_id = new.workspace_id and role <> 'admin';
  elsif exists (select 1 from public.blocked where user_id = uid and workspace_id = new.workspace_id)
        and not exists (select 1 from public.members where user_id = uid) then
    -- restored: lift the block and give the matching access back
    delete from public.blocked where user_id = uid and workspace_id = new.workspace_id;
    insert into public.members (user_id, email, role, workspace_id)
      select uid, u.email, case when r = 'viewer' then 'viewer' else 'member' end, new.workspace_id from auth.users u where u.id = uid;
  end if;
  return new;
end
$$;
drop trigger if exists kv_team_role on public.kv;
create trigger kv_team_role after insert or update on public.kv
  for each row execute function public.sync_team_role();

-- ---------------------------------------------------------------------------
-- Access rules (row-level security): everything is limited to the signed-in person's own workspace
-- ---------------------------------------------------------------------------

alter table public.workspaces enable row level security;
alter table public.members    enable row level security;
alter table public.invites    enable row level security;
alter table public.settings   enable row level security;
alter table public.profiles   enable row level security;
alter table public.kv         enable row level security;
alter table public.blocked    enable row level security;

drop policy if exists workspaces_read on public.workspaces;
drop policy if exists workspaces_admin on public.workspaces;
create policy workspaces_read  on public.workspaces for select using (id = public.my_ws());
create policy workspaces_admin on public.workspaces for update using (id = public.my_ws() and public.my_role() = 'admin') with check (id = public.my_ws());

drop policy if exists kv_read on public.kv;
drop policy if exists kv_insert on public.kv;
drop policy if exists kv_update on public.kv;
drop policy if exists kv_delete on public.kv;
create policy kv_read   on public.kv for select using (workspace_id = public.my_ws());
create policy kv_insert on public.kv for insert with check (workspace_id = public.my_ws() and public.can_write(path) and collection = regexp_replace(path, '/[^/]+$', ''));
create policy kv_update on public.kv for update using (workspace_id = public.my_ws() and public.can_write(path))
  with check (workspace_id = public.my_ws() and public.can_write(path) and collection = regexp_replace(path, '/[^/]+$', ''));
create policy kv_delete on public.kv for delete using (workspace_id = public.my_ws() and public.can_write(path));

drop policy if exists members_read on public.members;
drop policy if exists members_admin_update on public.members;
drop policy if exists members_admin_delete on public.members;
create policy members_read         on public.members for select using (workspace_id = public.my_ws());
create policy members_admin_update on public.members for update using (workspace_id = public.my_ws() and public.my_role() = 'admin') with check (workspace_id = public.my_ws());
create policy members_admin_delete on public.members for delete using (workspace_id = public.my_ws() and public.my_role() = 'admin' and user_id <> auth.uid());

drop policy if exists invites_admin on public.invites;
create policy invites_admin on public.invites for all using (workspace_id = public.my_ws() and public.my_role() = 'admin') with check (workspace_id = public.my_ws() and public.my_role() = 'admin');

drop policy if exists blocked_admin on public.blocked;
create policy blocked_admin on public.blocked for all using (workspace_id = public.my_ws() and public.my_role() = 'admin') with check (workspace_id = public.my_ws() and public.my_role() = 'admin');

drop policy if exists settings_read on public.settings;
drop policy if exists settings_admin on public.settings;

-- you see your own profile and the people in your workspace, nobody else
drop policy if exists profiles_read on public.profiles;
drop policy if exists profiles_self on public.profiles;
create policy profiles_read on public.profiles for select using (id = auth.uid() or exists (select 1 from public.members m where m.user_id = profiles.id and m.workspace_id = public.my_ws()));
create policy profiles_self on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

grant usage on schema public to authenticated;
grant select, insert, update, delete on public.kv to authenticated;
grant select, update, delete on public.members to authenticated;
grant select, insert, update, delete on public.invites to authenticated;
grant select, insert, delete on public.blocked to authenticated;
grant select on public.workspaces to authenticated;
revoke update on public.workspaces from authenticated;
grant update (name, allowed_domain, require_mfa, idle_minutes) on public.workspaces to authenticated;
revoke all on public.settings from authenticated;
grant select, update on public.profiles to authenticated;
grant execute on function public.signed_in_with_mfa(), public.my_ws(), public.my_role(), public.my_workspace(), public.can_write(text), public.join_workspace() to authenticated;
revoke all on public.kv, public.members, public.invites, public.settings, public.profiles, public.blocked, public.workspaces from anon;

-- ---------------------------------------------------------------------------
-- Audit log: who did what, and when. Written only by the database itself; nobody can edit or delete it
-- from the app, and only a workspace's admins can read its entries. Kept after a workspace is deleted.
-- ---------------------------------------------------------------------------

create table if not exists public.audit_log (
  id           bigserial primary key,
  workspace_id uuid not null,
  at           timestamptz not null default now(),
  actor        uuid,
  actor_email  text,
  action       text not null,
  target       text,
  detail       jsonb not null default '{}'::jsonb
);
create index if not exists audit_ws_at_idx on public.audit_log (workspace_id, at desc);

create or replace function public.audit(ws uuid, act text, tgt text, det jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if ws is null then return; end if;
  -- deleting a workspace removes its records in one sweep; log the deletion once, not every row
  if current_setting('dealbasis.deleting', true) = ws::text and act <> 'workspace.deleted' then return; end if;
  insert into public.audit_log (workspace_id, actor, actor_email, action, target, detail)
  values (ws, auth.uid(), (select u.email from auth.users u where u.id = auth.uid()), act, tgt, coalesce(det, '{}'::jsonb));
end
$$;
revoke all on function public.audit(uuid, text, text, jsonb) from public, anon, authenticated;

-- deal records: created, changed (once per person per record every 10 minutes, so autosave doesn't flood it), deleted
create or replace function public.audit_kv() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; act text; nm text;
begin
  r := case when tg_op = 'DELETE' then old else new end;
  if r.collection = 'people' then return null; end if;   -- presence pings, not changes
  act := case when tg_op = 'INSERT' then 'record.created' when tg_op = 'UPDATE' then 'record.updated' else 'record.deleted' end;
  if tg_op = 'UPDATE' and exists (select 1 from public.audit_log a where a.workspace_id = r.workspace_id and a.target = r.path
       and a.actor is not distinct from auth.uid() and a.action in ('record.updated', 'record.created') and a.at > now() - interval '10 minutes') then
    return null;
  end if;
  nm := coalesce(r.data ->> 'name', r.data ->> 'project', r.data ->> 'title', r.data #>> '{meta,project}');
  perform public.audit(r.workspace_id, act, r.path, case when nm is null then '{}'::jsonb else jsonb_build_object('name', nm) end);
  return null;
end
$$;
drop trigger if exists kv_audit on public.kv;
create trigger kv_audit after insert or update or delete on public.kv for each row execute function public.audit_kv();

create or replace function public.audit_members() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform public.audit(new.workspace_id, 'member.joined', new.email, jsonb_build_object('role', new.role));
  elsif tg_op = 'UPDATE' then
    if new.workspace_id is distinct from old.workspace_id then
      perform public.audit(old.workspace_id, 'member.left', old.email, '{}'::jsonb);
      perform public.audit(new.workspace_id, 'member.joined', new.email, jsonb_build_object('role', new.role));
    elsif new.role is distinct from old.role then
      perform public.audit(new.workspace_id, 'member.role_changed', new.email, jsonb_build_object('from', old.role, 'to', new.role));
    end if;
  else
    perform public.audit(old.workspace_id, 'member.removed', old.email, jsonb_build_object('role', old.role));
  end if;
  return null;
end
$$;
drop trigger if exists members_audit on public.members;
create trigger members_audit after insert or update or delete on public.members for each row execute function public.audit_members();

create or replace function public.audit_invites() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.audit(new.workspace_id, 'invite.sent', new.email, jsonb_build_object('role', new.role));
  return null;
end
$$;
drop trigger if exists invites_audit on public.invites;
create trigger invites_audit after insert or update on public.invites for each row execute function public.audit_invites();

-- switching on required two-factor needs the admin to have passed it, so nobody locks themselves out
create or replace function public.guard_workspace() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.require_mfa and not old.require_mfa and auth.uid() is not null and not public.signed_in_with_mfa() then
    raise exception 'Set up two-factor sign-in for yourself, and sign in with it, before requiring it for everyone.' using errcode = '42501';
  end if;
  return new;
end
$$;
drop trigger if exists workspaces_guard on public.workspaces;
create trigger workspaces_guard before update on public.workspaces for each row execute function public.guard_workspace();

create or replace function public.audit_workspaces() returns trigger
language plpgsql security definer set search_path = public as $$
declare d jsonb := '{}'::jsonb;
begin
  if new.name is distinct from old.name then d := d || jsonb_build_object('name', new.name); end if;
  if new.allowed_domain is distinct from old.allowed_domain then d := d || jsonb_build_object('allowed_domain', new.allowed_domain); end if;
  if new.require_mfa is distinct from old.require_mfa then d := d || jsonb_build_object('require_mfa', new.require_mfa); end if;
  if new.idle_minutes is distinct from old.idle_minutes then d := d || jsonb_build_object('idle_minutes', new.idle_minutes); end if;
  if d <> '{}'::jsonb then perform public.audit(new.id, 'workspace.settings_changed', new.name, d); end if;
  return null;
end
$$;
drop trigger if exists workspaces_audit on public.workspaces;
create trigger workspaces_audit after update on public.workspaces for each row execute function public.audit_workspaces();

-- events only the browser sees: sign-ins, sign-outs, downloads, exports, two-factor changes
create or replace function public.log_event(act text, tgt text default null) returns void
language plpgsql security definer set search_path = public as $$
declare ws uuid;
begin
  if act not in ('auth.sign_in', 'auth.sign_out', 'auth.idle_sign_out', 'file.downloaded', 'workspace.exported', 'mfa.enrolled', 'mfa.removed') then
    raise exception 'Unknown event' using errcode = '22023';
  end if;
  select m.workspace_id into ws from public.members m where m.user_id = auth.uid();
  perform public.audit(ws, act, left(tgt, 300), '{}'::jsonb);
end
$$;

-- Permanently delete the signed-in admin's workspace: deals, members, invites. The app removes the
-- workspace's files from storage first. The audit log keeps a record that it happened.
create or replace function public.delete_workspace(confirm_name text) returns void
language plpgsql security definer set search_path = public as $$
declare ws uuid := public.my_ws(); nm text;
begin
  if ws is null or public.my_role() <> 'admin' then raise exception 'Only an admin can delete the workspace.' using errcode = '42501'; end if;
  select name into nm from public.workspaces where id = ws;
  if confirm_name is distinct from nm then raise exception 'Type the workspace name exactly to confirm.' using errcode = '22023'; end if;
  perform public.audit(ws, 'workspace.deleted', nm, '{}'::jsonb);
  perform set_config('dealbasis.deleting', ws::text, true);
  delete from public.workspaces where id = ws;
end
$$;

alter table public.audit_log enable row level security;
drop policy if exists audit_admin_read on public.audit_log;
create policy audit_admin_read on public.audit_log for select using (workspace_id = public.my_ws() and public.my_role() = 'admin');
revoke all on public.audit_log from anon, authenticated;
grant select on public.audit_log to authenticated;
grant execute on function public.log_event(text, text), public.delete_workspace(text) to authenticated;

-- ---------------------------------------------------------------------------
-- File storage: uploaded documents and their originals (private bucket, 50 MB per file).
-- Each workspace's files sit in a folder named after the workspace, and only its members can reach them.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit)
values ('assets', 'assets', false, 52428800)
on conflict (id) do nothing;

-- files from before workspaces (no folder) belong to the workspace those deals moved into
create or replace function public.can_reach_file(name text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.my_ws() is not null and (
    split_part(name, '/', 1) = public.my_ws()::text
    or (position('/' in name) = 0 and exists (select 1 from public.workspaces w where w.id = public.my_ws() and w.legacy_files)))
$$;
grant execute on function public.can_reach_file(text) to authenticated;

drop policy if exists dealbasis_assets_read on storage.objects;
drop policy if exists dealbasis_assets_insert on storage.objects;
drop policy if exists dealbasis_assets_delete on storage.objects;
create policy dealbasis_assets_read   on storage.objects for select using (bucket_id = 'assets' and public.can_reach_file(name));
create policy dealbasis_assets_insert on storage.objects for insert with check (bucket_id = 'assets' and public.my_role() in ('admin', 'member') and split_part(name, '/', 1) = public.my_ws()::text);
create policy dealbasis_assets_delete on storage.objects for delete using (bucket_id = 'assets' and public.my_role() in ('admin', 'member') and public.can_reach_file(name));

-- uploads and deletions go in the audit log
create or replace function public.audit_files() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; ws uuid;
begin
  r := case when tg_op = 'DELETE' then old else new end;
  if r.bucket_id <> 'assets' then return null; end if;
  if position('/' in r.name) > 0 then
    begin ws := split_part(r.name, '/', 1)::uuid; exception when others then return null; end;
  else
    select id into ws from public.workspaces where legacy_files order by created_at limit 1;
  end if;
  perform public.audit(ws, case when tg_op = 'INSERT' then 'file.uploaded' else 'file.deleted' end, r.name, '{}'::jsonb);
  return null;
end
$$;
drop trigger if exists dealbasis_files_audit on storage.objects;
create trigger dealbasis_files_audit after insert or delete on storage.objects for each row execute function public.audit_files();

-- ---------------------------------------------------------------------------
-- Live updates: people in a workspace see its saved changes without reloading (row-level security applies)
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'kv') then
    alter publication supabase_realtime add table public.kv;
  end if;
end
$$;
