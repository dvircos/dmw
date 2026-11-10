-- Mordechai Winners: play-money Nations League schema.
-- Odds are read inside place_bet. Clients cannot write balances or bets directly.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null check (char_length(username) between 2 and 24),
  balance numeric(10,2) not null default 1000.00 check (balance >= 0),
  created_at timestamptz not null default now(),
  unique (username)
);

create table if not exists public.games (
  id bigserial primary key,
  fixture_id integer unique,
  home_team text not null,
  away_team text not null,
  home_flag text,
  away_flag text,
  match_time timestamptz not null,
  home_odds numeric(4,2),
  draw_odds numeric(4,2),
  away_odds numeric(4,2),
  home_score integer not null default 0,
  away_score integer not null default 0,
  status text not null default 'upcoming' check (status in ('upcoming', 'live', 'finished', 'cancelled')),
  round_name text,
  odds_locked boolean not null default false,
  result_confirmed boolean not null default false
);

create table if not exists public.bets (
  id bigserial primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  game_id bigint not null references public.games (id) on delete restrict,
  bet_selection text not null check (bet_selection in ('1', 'X', '2')),
  bet_amount numeric(10,2) not null check (bet_amount > 0),
  odds numeric(4,2) not null,
  potential_payout numeric(10,2) not null,
  status text not null default 'pending' check (status in ('pending', 'won', 'lost', 'void'))
);

create index if not exists games_match_time_idx on public.games (match_time);
create index if not exists bets_user_idx on public.bets (user_id);
create index if not exists bets_game_idx on public.bets (game_id);
create unique index if not exists bets_one_slip_per_selection
  on public.bets (user_id, game_id, bet_selection);

alter table public.profiles enable row level security;
alter table public.games enable row level security;
alter table public.bets enable row level security;

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles
  for select to anon, authenticated
  using (true);

drop policy if exists games_read on public.games;
create policy games_read on public.games
  for select to anon, authenticated
  using (true);

drop policy if exists bets_read_own on public.bets;
create policy bets_read_own on public.bets
  for select to authenticated
  using (user_id = auth.uid());

create or replace function public.insert_profile(p_id uuid, p_username text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := left(coalesce(nullif(trim(p_username), ''), 'שחקן'), 24);
begin
  begin
    insert into public.profiles (id, username) values (p_id, v_name);
  exception when unique_violation then
    insert into public.profiles (id, username)
    values (p_id, left(v_name, 18) || '-' || left(replace(p_id::text, '-', ''), 4))
    on conflict (id) do nothing;
  end;
end;
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.insert_profile(
    new.id,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1))
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.auto_confirm_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.email_confirmed_at is null then
    new.email_confirmed_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists auto_confirm_email on auth.users;
create trigger auto_confirm_email
  before insert on auth.users
  for each row execute function public.auto_confirm_email();

create or replace function public.ensure_profile()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_name text;
begin
  if v_uid is null then
    raise exception 'יש להתחבר';
  end if;
  if exists (select 1 from public.profiles where id = v_uid) then
    return;
  end if;
  select coalesce(nullif(trim(raw_user_meta_data->>'username'), ''), split_part(email, '@', 1))
    into v_name
  from auth.users
  where id = v_uid;
  perform public.insert_profile(v_uid, v_name);
end;
$$;

-- Odds and payout are calculated here. The client cannot choose them.
create or replace function public.place_bet(
  p_game_id bigint,
  p_selection text,
  p_amount numeric
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_game public.games%rowtype;
  v_amount numeric(10,2);
  v_odds numeric(4,2);
  v_payout numeric(10,2);
  v_balance numeric(10,2);
  v_bet_id bigint;
begin
  if v_uid is null then
    raise exception 'יש להתחבר';
  end if;
  if p_selection not in ('1', 'X', '2') then
    raise exception 'בחירה לא תקינה';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'סכום לא תקין';
  end if;

  v_amount := round(p_amount, 2);
  if v_amount <= 0 then
    raise exception 'סכום לא תקין';
  end if;

  select * into v_game
  from public.games
  where id = p_game_id
  for update;

  if not found then
    raise exception 'המשחק לא נמצא';
  end if;

  if v_game.status <> 'upcoming'
     or v_game.match_time is null
     or v_game.match_time <= now() + interval '5 minutes' then
    raise exception 'ההימור נעול — נותרו פחות מ־5 דקות לתחילת המשחק';
  end if;

  v_odds := case p_selection
    when '1' then v_game.home_odds
    when 'X' then v_game.draw_odds
    when '2' then v_game.away_odds
  end;

  if v_odds is null or v_odds < 1.01 then
    raise exception 'היחס לא זמין';
  end if;

  if v_amount * v_odds > 99999999.99 then
    raise exception 'הסכום חורג מהתקרה';
  end if;

  v_payout := round(v_amount * v_odds, 2);

  select balance into v_balance
  from public.profiles
  where id = v_uid
  for update;

  if not found then
    raise exception 'הפרופיל לא נמצא';
  end if;
  if v_balance < v_amount then
    raise exception 'יתרה לא מספיקה';
  end if;

  update public.profiles
  set balance = balance - v_amount
  where id = v_uid;

  begin
    insert into public.bets (
      user_id, game_id, bet_selection, bet_amount, odds, potential_payout, status
    ) values (
      v_uid, p_game_id, p_selection, v_amount, v_odds, v_payout, 'pending'
    )
    returning id into v_bet_id;
  exception when unique_violation then
    raise exception 'כבר קיים הימור על הבחירה הזו';
  end;

  select balance into v_balance from public.profiles where id = v_uid;

  return jsonb_build_object(
    'bet_id', v_bet_id,
    'odds', v_odds,
    'potential_payout', v_payout,
    'balance', v_balance
  );
end;
$$;

-- Settlement uses the 90-minute score passed by the sync job, never extra time.
create or replace function public.sync_game_result(
  p_fixture_id integer,
  p_home_team text,
  p_away_team text,
  p_home_flag text,
  p_away_flag text,
  p_match_time timestamptz,
  p_home_odds numeric,
  p_draw_odds numeric,
  p_away_odds numeric,
  p_home_score integer,
  p_away_score integer,
  p_status text,
  p_round_name text default null,
  p_lock_odds boolean default false,
  p_confirm_result boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game public.games%rowtype;
  v_settled integer := 0;
  v_bet record;
  v_won boolean;
begin
  if p_status not in ('upcoming', 'live', 'finished', 'cancelled') then
    raise exception 'invalid status';
  end if;
  if p_home_team is null or p_away_team is null or p_match_time is null then
    raise exception 'incomplete fixture';
  end if;

  if p_home_odds is not null and (p_home_odds < 1.01 or p_home_odds > 99.99) then
    p_home_odds := null;
  end if;
  if p_draw_odds is not null and (p_draw_odds < 1.01 or p_draw_odds > 99.99) then
    p_draw_odds := null;
  end if;
  if p_away_odds is not null and (p_away_odds < 1.01 or p_away_odds > 99.99) then
    p_away_odds := null;
  end if;

  insert into public.games (
    fixture_id, home_team, away_team, home_flag, away_flag, match_time,
    home_odds, draw_odds, away_odds, home_score, away_score, status,
    round_name, odds_locked, result_confirmed
  ) values (
    p_fixture_id, p_home_team, p_away_team, p_home_flag, p_away_flag, p_match_time,
    p_home_odds, p_draw_odds, p_away_odds,
    case
      when coalesce(p_confirm_result, false) and p_status in ('finished', 'cancelled') then coalesce(p_home_score, 0)
      else 0
    end,
    case
      when coalesce(p_confirm_result, false) and p_status in ('finished', 'cancelled') then coalesce(p_away_score, 0)
      else 0
    end,
    case
      when coalesce(p_confirm_result, false) and p_status in ('finished', 'cancelled') then p_status
      else 'upcoming'
    end,
    p_round_name,
    coalesce(p_lock_odds, false)
      and p_home_odds is not null and p_draw_odds is not null and p_away_odds is not null,
    coalesce(p_confirm_result, false) and p_status in ('finished', 'cancelled')
  )
  on conflict (fixture_id) do update set
    home_team = excluded.home_team,
    away_team = excluded.away_team,
    home_flag = excluded.home_flag,
    away_flag = excluded.away_flag,
    match_time = excluded.match_time,
    round_name = coalesce(excluded.round_name, games.round_name),
    home_odds = case
      when games.odds_locked then games.home_odds
      when excluded.odds_locked then excluded.home_odds
      else coalesce(excluded.home_odds, games.home_odds)
    end,
    draw_odds = case
      when games.odds_locked then games.draw_odds
      when excluded.odds_locked then excluded.draw_odds
      else coalesce(excluded.draw_odds, games.draw_odds)
    end,
    away_odds = case
      when games.odds_locked then games.away_odds
      when excluded.odds_locked then excluded.away_odds
      else coalesce(excluded.away_odds, games.away_odds)
    end,
    odds_locked = games.odds_locked or excluded.odds_locked,
    home_score = case
      when games.result_confirmed or games.status in ('finished', 'cancelled') then games.home_score
      when excluded.status in ('finished', 'cancelled') then excluded.home_score
      else games.home_score
    end,
    away_score = case
      when games.result_confirmed or games.status in ('finished', 'cancelled') then games.away_score
      when excluded.status in ('finished', 'cancelled') then excluded.away_score
      else games.away_score
    end,
    status = case
      when games.result_confirmed or games.status in ('finished', 'cancelled') then games.status
      when excluded.status in ('finished', 'cancelled') then excluded.status
      else games.status
    end,
    result_confirmed = games.result_confirmed or excluded.result_confirmed
  returning * into v_game;

  if v_game.status = 'finished' then
    for v_bet in
      select * from public.bets
      where game_id = v_game.id and status = 'pending'
      order by id
      for update
    loop
      v_won := (v_bet.bet_selection = '1' and v_game.home_score > v_game.away_score)
        or (v_bet.bet_selection = 'X' and v_game.home_score = v_game.away_score)
        or (v_bet.bet_selection = '2' and v_game.home_score < v_game.away_score);
      if v_won then
        update public.bets set status = 'won' where id = v_bet.id;
        update public.profiles
        set balance = balance + v_bet.potential_payout
        where id = v_bet.user_id;
      else
        update public.bets set status = 'lost' where id = v_bet.id;
      end if;
      v_settled := v_settled + 1;
    end loop;
  elsif v_game.status = 'cancelled' then
    for v_bet in
      select * from public.bets
      where game_id = v_game.id and status = 'pending'
      order by id
      for update
    loop
      update public.bets set status = 'void' where id = v_bet.id;
      update public.profiles
      set balance = balance + v_bet.bet_amount
      where id = v_bet.user_id;
      v_settled := v_settled + 1;
    end loop;
  end if;

  return jsonb_build_object(
    'fixture_id', p_fixture_id,
    'status', v_game.status,
    'home_score', v_game.home_score,
    'away_score', v_game.away_score,
    'settled', v_settled
  );
end;
$$;

create table if not exists public.api_quota (
  id integer primary key default 1 check (id = 1),
  day_key date not null default (timezone('utc', now()))::date,
  day_count integer not null default 0 check (day_count >= 0),
  month_key text not null default to_char(timezone('utc', now()), 'YYYY-MM'),
  month_count integer not null default 0 check (month_count >= 0)
);

insert into public.api_quota (id) values (1) on conflict (id) do nothing;

create table if not exists public.api_request_log (
  id bigserial primary key,
  called_at timestamptz not null default now(),
  endpoint text not null,
  params jsonb,
  status_code integer,
  purpose text not null
);

create table if not exists public.api_cache (
  cache_key text primary key,
  payload jsonb not null,
  fetched_at timestamptz not null default now()
);

alter table public.api_quota enable row level security;
alter table public.api_request_log enable row level security;
alter table public.api_cache enable row level security;

create or replace function public.reserve_api_requests(p_count integer, p_emergency boolean default false)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.api_quota%rowtype;
  v_today date := (timezone('utc', now()))::date;
  v_month text := to_char(timezone('utc', now()), 'YYYY-MM');
  v_limit integer := case when p_emergency then 100 else 80 end;
begin
  if p_count is null or p_count <= 0 then
    raise exception 'invalid request count';
  end if;
  select * into v_row from public.api_quota where id = 1 for update;
  if not found then
    insert into public.api_quota (id) values (1);
    select * into v_row from public.api_quota where id = 1 for update;
  end if;
  if v_row.day_key <> v_today then
    v_row.day_key := v_today;
    v_row.day_count := 0;
  end if;
  if v_row.month_key <> v_month then
    v_row.month_key := v_month;
    v_row.month_count := 0;
  end if;
  if v_row.day_count + p_count > v_limit then
    update public.api_quota
    set day_key = v_row.day_key, day_count = v_row.day_count,
        month_key = v_row.month_key, month_count = v_row.month_count
    where id = 1;
    return false;
  end if;
  update public.api_quota
  set day_key = v_row.day_key,
      day_count = v_row.day_count + p_count,
      month_key = v_row.month_key,
      month_count = v_row.month_count + p_count
  where id = 1;
  return true;
end;
$$;

create or replace function public.read_api_cache(p_key text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select payload from public.api_cache where cache_key = p_key;
$$;

create or replace function public.write_api_cache(p_key text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.api_cache (cache_key, payload, fetched_at)
  values (p_key, p_payload, now())
  on conflict (cache_key) do update
  set payload = excluded.payload, fetched_at = now();
end;
$$;

create or replace function public.log_api_request(
  p_endpoint text,
  p_params jsonb,
  p_status integer,
  p_purpose text
) returns void
language sql
security definer
set search_path = public
as $$
  insert into public.api_request_log (endpoint, params, status_code, purpose)
  values (p_endpoint, p_params, p_status, p_purpose);
$$;

create or replace function public.edit_bet(
  p_bet_id bigint,
  p_selection text,
  p_amount numeric
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_bet public.bets%rowtype;
  v_game public.games%rowtype;
  v_amount numeric(10,2);
  v_odds numeric(4,2);
  v_payout numeric(10,2);
  v_balance numeric(10,2);
begin
  if v_uid is null then
    raise exception 'יש להתחבר';
  end if;
  if p_selection not in ('1', 'X', '2') then
    raise exception 'בחירה לא תקינה';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'סכום לא תקין';
  end if;
  v_amount := round(p_amount, 2);
  if v_amount <= 0 then
    raise exception 'סכום לא תקין';
  end if;

  select * into v_bet
  from public.bets
  where id = p_bet_id and user_id = v_uid
  for update;
  if not found then
    raise exception 'ההימור לא נמצא';
  end if;
  if v_bet.status <> 'pending' then
    raise exception 'אפשר לערוך רק הימור ממתין';
  end if;

  select * into v_game
  from public.games
  where id = v_bet.game_id
  for update;
  if not found then
    raise exception 'המשחק לא נמצא';
  end if;
  if v_game.match_time is null or v_game.match_time <= now() then
    raise exception 'המשחק כבר התחיל';
  end if;

  if exists (
    select 1 from public.bets
    where user_id = v_uid
      and game_id = v_bet.game_id
      and bet_selection = p_selection
      and id <> v_bet.id
  ) then
    raise exception 'כבר קיים הימור על הבחירה הזו';
  end if;

  if p_selection = v_bet.bet_selection then
    v_odds := v_bet.odds;
  else
    v_odds := case p_selection
      when '1' then v_game.home_odds
      when 'X' then v_game.draw_odds
      else v_game.away_odds
    end;
  end if;
  if v_odds is null or v_odds < 1.01 then
    raise exception 'היחס לא זמין';
  end if;
  if v_amount * v_odds > 99999999.99 then
    raise exception 'הסכום חורג מהתקרה';
  end if;
  v_payout := round(v_amount * v_odds, 2);

  select balance into v_balance
  from public.profiles
  where id = v_uid
  for update;
  if v_balance + v_bet.bet_amount < v_amount then
    raise exception 'יתרה לא מספיקה';
  end if;

  update public.profiles
  set balance = balance + v_bet.bet_amount - v_amount
  where id = v_uid;

  begin
    update public.bets
    set bet_selection = p_selection,
        bet_amount = v_amount,
        odds = v_odds,
        potential_payout = v_payout
    where id = v_bet.id;
  exception when unique_violation then
    raise exception 'כבר קיים הימור על הבחירה הזו';
  end;

  select balance into v_balance from public.profiles where id = v_uid;
  return jsonb_build_object(
    'bet_id', v_bet.id,
    'bet_selection', p_selection,
    'bet_amount', v_amount,
    'odds', v_odds,
    'potential_payout', v_payout,
    'balance', v_balance
  );
end;
$$;

do $$
declare
  r record;
begin
  for r in
    select p.proname, p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('edit_bet', 'reserve_api_requests', 'read_api_cache', 'write_api_cache', 'log_api_request', 'sync_game_result')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    if r.proname = 'edit_bet' then
      execute format('grant execute on function %s to authenticated', r.sig);
    elsif exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', r.sig);
    end if;
  end loop;
end $$;


do $$
declare
  r record;
  v_role text;
begin
  for r in
    select p.proname, p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'insert_profile', 'handle_new_user', 'auto_confirm_email', 'ensure_profile',
        'place_bet', 'edit_bet', 'sync_game_result',
        'reserve_api_requests', 'read_api_cache', 'write_api_cache', 'log_api_request'
      )
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    if r.proname in ('place_bet', 'ensure_profile', 'edit_bet') then
      execute format('grant execute on function %s to authenticated', r.sig);
    elsif r.proname in ('sync_game_result', 'reserve_api_requests', 'read_api_cache', 'write_api_cache', 'log_api_request') then
      if exists (select 1 from pg_roles where rolname = 'service_role') then
        execute format('grant execute on function %s to service_role', r.sig);
      end if;
    elsif r.proname in ('handle_new_user', 'auto_confirm_email') then
      foreach v_role in array array['supabase_auth_admin', 'service_role', 'postgres']
      loop
        if exists (select 1 from pg_roles where rolname = v_role) then
          execute format('grant execute on function %s to %I', r.sig, v_role);
        end if;
      end loop;
    end if;
  end loop;
end $$;

do $$
declare
  v_table text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach v_table in array array['games', 'bets', 'profiles']
    loop
      if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = v_table
      ) then
        execute format('alter publication supabase_realtime add table public.%I', v_table);
      end if;
    end loop;
  end if;
end $$;

insert into public.games (
  fixture_id, home_team, away_team, home_flag, away_flag, match_time,
  home_odds, draw_odds, away_odds, home_score, away_score, status
)
select 900001, 'ספרד', 'הולנד', 'https://flagcdn.com/w80/es.png', 'https://flagcdn.com/w80/nl.png', now() + interval '3 days', 2.05, 3.30, 3.55, 0, 0, 'upcoming'
where not exists (select 1 from public.games where fixture_id = 900001);

insert into public.games (
  fixture_id, home_team, away_team, home_flag, away_flag, match_time,
  home_odds, draw_odds, away_odds, home_score, away_score, status
)
select 900002, 'צרפת', 'איטליה', 'https://flagcdn.com/w80/fr.png', 'https://flagcdn.com/w80/it.png', now() + interval '4 days', 2.40, 3.10, 3.05, 0, 0, 'upcoming'
where not exists (select 1 from public.games where fixture_id = 900002);

insert into public.games (
  fixture_id, home_team, away_team, home_flag, away_flag, match_time,
  home_odds, draw_odds, away_odds, home_score, away_score, status
)
select 900003, 'אנגליה', 'גרמניה', 'https://flagcdn.com/w80/gb-eng.png', 'https://flagcdn.com/w80/de.png', now() + interval '4 days 3 hours', 2.55, 3.20, 2.75, 0, 0, 'upcoming'
where not exists (select 1 from public.games where fixture_id = 900003);

insert into public.games (
  fixture_id, home_team, away_team, home_flag, away_flag, match_time,
  home_odds, draw_odds, away_odds, home_score, away_score, status
)
select 900004, 'פורטוגל', 'קרואטיה', 'https://flagcdn.com/w80/pt.png', 'https://flagcdn.com/w80/hr.png', now() + interval '5 days', 2.15, 3.15, 3.50, 0, 0, 'upcoming'
where not exists (select 1 from public.games where fixture_id = 900004);

insert into public.games (
  fixture_id, home_team, away_team, home_flag, away_flag, match_time,
  home_odds, draw_odds, away_odds, home_score, away_score, status
)
select 900005, 'ישראל', 'בלגיה', 'https://flagcdn.com/w80/il.png', 'https://flagcdn.com/w80/be.png', now() + interval '6 days', 4.40, 3.45, 1.80, 0, 0, 'upcoming'
where not exists (select 1 from public.games where fixture_id = 900005);

insert into public.games (
  fixture_id, home_team, away_team, home_flag, away_flag, match_time,
  home_odds, draw_odds, away_odds, home_score, away_score, status
)
select 900006, 'סקוטלנד', 'דנמרק', 'https://flagcdn.com/w80/gb-sct.png', 'https://flagcdn.com/w80/dk.png', now() + interval '6 days 2 hours', 3.10, 3.20, 2.30, 0, 0, 'upcoming'
where not exists (select 1 from public.games where fixture_id = 900006);

insert into public.games (
  fixture_id, home_team, away_team, home_flag, away_flag, match_time,
  home_odds, draw_odds, away_odds, home_score, away_score, status
)
select 900007, 'אוסטריה', 'טורקיה', 'https://flagcdn.com/w80/at.png', 'https://flagcdn.com/w80/tr.png', now() - interval '35 minutes', 2.70, 3.15, 2.60, 1, 0, 'live'
where not exists (select 1 from public.games where fixture_id = 900007);

insert into public.games (
  fixture_id, home_team, away_team, home_flag, away_flag, match_time,
  home_odds, draw_odds, away_odds, home_score, away_score, status
)
select 900008, 'שווייץ', 'נורווגיה', 'https://flagcdn.com/w80/ch.png', 'https://flagcdn.com/w80/no.png', now() - interval '3 days', 2.20, 3.25, 3.30, 2, 1, 'finished'
where not exists (select 1 from public.games where fixture_id = 900008);
