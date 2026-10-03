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
