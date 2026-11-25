-- Carvital database schema for Supabase.
-- Run this once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Create the project in an EU region (e.g. "Central EU (Frankfurt)") so all data stays in the EU.

-- ---------- profiles ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null default '',
  notify_apk boolean not null default true,
  notify_maintenance boolean not null default true,
  marketing_opt_in boolean not null default false,
  marketing_opt_in_at timestamptz,
  terms_version text,
  terms_accepted_at timestamptz,
  created_at timestamptz not null default now()
);

-- ---------- cars ----------
create table if not exists public.cars (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade default auth.uid(),
  kenteken text not null,
  merk text,
  model text,
  bouwjaar int,
  brandstof text,
  kleur text,
  apk_vervaldatum date,
  kilometerstand int,
  created_at timestamptz not null default now(),
  unique (user_id, kenteken)
);

-- ---------- maintenance records (onderhoudsboekje) ----------
create table if not exists public.maintenance_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade default auth.uid(),
  car_id uuid not null references public.cars (id) on delete cascade,
  datum date not null,
  kilometerstand int,
  omschrijving text not null,
  categorie text not null default 'overig'
    check (categorie in ('onderhoud', 'apk', 'remmen', 'banden', 'reparatie', 'overig')),
  garage text,
  bedrag numeric(10, 2),
  invoice_path text,
  created_at timestamptz not null default now()
);

create index if not exists cars_user_idx on public.cars (user_id);
create index if not exists records_car_idx on public.maintenance_records (car_id, datum desc);

-- ---------- row level security: every user only sees their own rows ----------
alter table public.profiles enable row level security;
alter table public.cars enable row level security;
alter table public.maintenance_records enable row level security;

drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles
  for all using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "own cars" on public.cars;
create policy "own cars" on public.cars
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own records" on public.maintenance_records;
create policy "own records" on public.maintenance_records
  for all using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.cars c where c.id = car_id and c.user_id = auth.uid())
  );

-- ---------- create a profile automatically on sign-up ----------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, name, marketing_opt_in, marketing_opt_in_at, terms_version, terms_accepted_at)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', ''),
    coalesce((new.raw_user_meta_data ->> 'marketing_opt_in')::boolean, false),
    case when coalesce((new.raw_user_meta_data ->> 'marketing_opt_in')::boolean, false) then now() end,
    new.raw_user_meta_data ->> 'terms_version',
    (new.raw_user_meta_data ->> 'terms_accepted_at')::timestamptz
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- AVG art. 17: let a user delete their own account ----------
-- Deleting the auth user cascades to profiles, cars and maintenance_records.
-- Invoice files are removed by the frontend via the Storage API first.
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- ---------- private storage bucket for invoices ----------
-- Files are stored as invoices/<user id>/<file>; users can only touch their own folder.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('invoices', 'invoices', false, 20971520, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;

drop policy if exists "own invoices select" on storage.objects;
create policy "own invoices select" on storage.objects
  for select to authenticated
  using (bucket_id = 'invoices' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "own invoices insert" on storage.objects;
create policy "own invoices insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'invoices' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "own invoices delete" on storage.objects;
create policy "own invoices delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'invoices' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- share links: hand the maintenance history to a buyer ----------
-- The owner creates a link for one car. Anyone with the token can read that car's history
-- through get_shared_history(), without logging in. Names, e-mail and invoices are never shared.
create table if not exists public.share_links (
  token text primary key default replace(gen_random_uuid()::text, '-', ''),
  user_id uuid not null references auth.users (id) on delete cascade default auth.uid(),
  car_id uuid not null references public.cars (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (car_id)
);

alter table public.share_links enable row level security;

drop policy if exists "own share links" on public.share_links;
create policy "own share links" on public.share_links
  for all using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.cars c where c.id = car_id and c.user_id = auth.uid())
  );

create or replace function public.get_shared_history(p_token text)
returns json
language sql
stable
security definer set search_path = ''
as $$
  select json_build_object(
    'shared_at', s.created_at,
    'car', json_build_object(
      'kenteken', c.kenteken, 'merk', c.merk, 'model', c.model, 'bouwjaar', c.bouwjaar,
      'brandstof', c.brandstof, 'kleur', c.kleur, 'apk_vervaldatum', c.apk_vervaldatum,
      'kilometerstand', c.kilometerstand
    ),
    'records', coalesce((
      select json_agg(json_build_object(
        'datum', r.datum, 'kilometerstand', r.kilometerstand, 'omschrijving', r.omschrijving,
        'categorie', r.categorie, 'garage', r.garage, 'bedrag', r.bedrag,
        'has_invoice', r.invoice_path is not null
      ) order by r.datum desc, r.created_at desc)
      from public.maintenance_records r where r.car_id = c.id
    ), '[]'::json)
  )
  from public.share_links s
  join public.cars c on c.id = s.car_id
  where s.token = p_token;
$$;

revoke all on function public.get_shared_history(text) from public;
grant execute on function public.get_shared_history(text) to anon, authenticated;

-- ---------- AI-uitlezing van facturen: daglimiet per gebruiker ----------
-- De Edge Function parse-invoice telt hier hoeveel facturen iemand in 24 uur liet uitlezen.
-- Gebruikers kunnen alleen rijen toevoegen en lezen, niet verwijderen, dus de limiet is niet te omzeilen.
create table if not exists public.invoice_parses (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists invoice_parses_user_idx on public.invoice_parses (user_id, created_at desc);

alter table public.invoice_parses enable row level security;

drop policy if exists "own parses select" on public.invoice_parses;
create policy "own parses select" on public.invoice_parses
  for select using (user_id = auth.uid());

drop policy if exists "own parses insert" on public.invoice_parses;
create policy "own parses insert" on public.invoice_parses
  for insert with check (user_id = auth.uid());

-- ---------- admin-rol ----------
-- Alleen in te stellen via de SQL Editor of het dashboard, nooit door de gebruiker zelf:
--   update public.profiles set is_admin = true
--   where id = (select id from auth.users where email = 'jij@voorbeeld.nl');
alter table public.profiles add column if not exists is_admin boolean not null default false;

-- Gebruikers mogen hun eigen profiel aanpassen (RLS), maar nooit is_admin.
-- Via de app (rol anon/authenticated) blijft is_admin altijd zoals het was.
create or replace function public.protect_is_admin()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') in ('anon', 'authenticated') then
    if tg_op = 'INSERT' then
      new.is_admin := false;
    else
      new.is_admin := old.is_admin;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists protect_is_admin on public.profiles;
create trigger protect_is_admin
  before insert or update on public.profiles
  for each row execute function public.protect_is_admin();

-- Statistieken voor beheerders: alleen totalen, geen gegevens van individuele gebruikers.
create or replace function public.admin_stats()
returns json
language plpgsql
stable
security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return json_build_object(
    'users_total', (select count(*) from auth.users),
    'users_confirmed', (select count(*) from auth.users where email_confirmed_at is not null),
    'users_7d', (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'users_30d', (select count(*) from auth.users where created_at > now() - interval '30 days'),
    'active_30d', (select count(*) from auth.users where last_sign_in_at > now() - interval '30 days'),
    'marketing_opt_in', (select count(*) from public.profiles where marketing_opt_in),
    'cars', (select count(*) from public.cars),
    'records', (select count(*) from public.maintenance_records),
    'records_30d', (select count(*) from public.maintenance_records where created_at > now() - interval '30 days'),
    'invoices', (select count(*) from public.maintenance_records where invoice_path is not null),
    'invoice_parses_30d', (select count(*) from public.invoice_parses where created_at > now() - interval '30 days'),
    'share_links', (select count(*) from public.share_links),
    'signups_per_week', coalesce((
      select json_agg(json_build_object('week', w.week, 'count', w.n) order by w.week)
      from (
        select gs::date as week,
               (select count(*) from auth.users u
                 where u.created_at >= gs and u.created_at < gs + interval '7 days') as n
        from generate_series(date_trunc('week', now()) - interval '11 weeks', date_trunc('week', now()), interval '1 week') gs
      ) w
    ), '[]'::json)
  );
end;
$$;

revoke all on function public.admin_stats() from public, anon;
grant execute on function public.admin_stats() to authenticated;

-- ---------- APK-herinneringen per e-mail ----------
-- De Edge Function send-reminders draait elke ochtend (zie README) en mailt 30 dagen voor de APK-vervaldatum.
-- Per auto en APK-datum gaat er maar één herinnering uit; deze tabel onthoudt welke al verstuurd zijn.
create table if not exists public.apk_reminders_sent (
  car_id uuid not null references public.cars (id) on delete cascade,
  apk_date date not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (car_id, apk_date)
);
-- RLS aan zonder policies: alleen de server (service_role) kan erbij
alter table public.apk_reminders_sent enable row level security;

-- Auto's waarvan de APK binnen p_days verloopt, van gebruikers die herinneringen willen
-- en een bevestigd e-mailadres hebben, en die voor deze APK-datum nog geen mail kregen.
create or replace function public.due_apk_reminders(p_days int default 30)
returns table (
  user_id uuid, email text, name text, car_id uuid, kenteken text, merk text, model text, apk_vervaldatum date
)
language sql
stable
security definer set search_path = ''
as $$
  select u.id, u.email::text, p.name, c.id, c.kenteken, c.merk, c.model, c.apk_vervaldatum
  from public.cars c
  join auth.users u on u.id = c.user_id
  join public.profiles p on p.id = c.user_id
  where p.notify_apk
    and u.email_confirmed_at is not null
    and c.apk_vervaldatum between current_date and current_date + p_days
    and not exists (
      select 1 from public.apk_reminders_sent s
      where s.car_id = c.id and s.apk_date = c.apk_vervaldatum
    );
$$;

revoke all on function public.due_apk_reminders(int) from public, anon, authenticated;
grant execute on function public.due_apk_reminders(int) to service_role;
