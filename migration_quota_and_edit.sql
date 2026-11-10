-- Adds odds locking, result confirmation, API quota, and in-place bet editing.
-- Existing rows are kept.

alter table public.games add column if not exists round_name text;
alter table public.games add column if not exists odds_locked boolean not null default false;
alter table public.games add column if not exists result_confirmed boolean not null default false;

drop function if exists public.sync_game_result(integer, text, text, text, text, timestamptz, numeric, numeric, numeric, integer, integer, text);
drop function if exists public.sync_game_result(integer, text, text, text, text, timestamptz, numeric, numeric, numeric, integer, integer, text, text, boolean, boolean);

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
