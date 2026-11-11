alter table public.bets alter column game_id drop not null;
alter table public.bets alter column bet_selection drop not null;
alter table public.bets alter column odds type numeric(14,4);
alter table public.bets alter column potential_payout type numeric(14,2);

create table if not exists public.bet_items (
  id bigserial primary key,
  bet_id bigint not null references public.bets (id) on delete cascade,
  game_id bigint not null references public.games (id) on delete restrict,
  bet_selection text not null check (bet_selection in ('1', 'X', '2')),
  odds numeric(8,2) not null check (odds >= 1.01),
  status text not null default 'pending' check (status in ('pending', 'won', 'lost', 'void')),
  unique (bet_id, game_id)
);

create index if not exists bet_items_game_idx on public.bet_items (game_id);
create index if not exists bet_items_bet_idx on public.bet_items (bet_id);

alter table public.bet_items enable row level security;

drop policy if exists bet_items_read_own on public.bet_items;
create policy bet_items_read_own on public.bet_items
  for select to authenticated
  using (
    exists (
      select 1 from public.bets
      where bets.id = bet_items.bet_id and bets.user_id = auth.uid()
    )
  );

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
  v_item record;
  v_leg record;
  v_slip public.bets%rowtype;
  v_won boolean;
  v_product numeric;
  v_payout numeric(14,2);
  v_legs integer;
  v_voids integer;
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

  if v_game.status in ('finished', 'cancelled') then
    for v_bet in
      select * from public.bets
      where game_id = v_game.id
        and status = 'pending'
        and not exists (select 1 from public.bet_items i where i.bet_id = bets.id)
      order by id
      for update
    loop
      if v_game.status = 'cancelled' then
        update public.bets set status = 'void' where id = v_bet.id;
        update public.profiles
        set balance = balance + v_bet.bet_amount
        where id = v_bet.user_id;
      else
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
      end if;
      v_settled := v_settled + 1;
    end loop;

    for v_item in
      select i.*
      from public.bet_items i
      join public.bets b on b.id = i.bet_id
      where i.game_id = v_game.id
        and i.status = 'pending'
        and b.status = 'pending'
      order by i.id
      for update of i
    loop
      if v_game.status = 'cancelled' then
        update public.bet_items set status = 'void' where id = v_item.id;
      else
        v_won := (v_item.bet_selection = '1' and v_game.home_score > v_game.away_score)
          or (v_item.bet_selection = 'X' and v_game.home_score = v_game.away_score)
          or (v_item.bet_selection = '2' and v_game.home_score < v_game.away_score);
        update public.bet_items
        set status = case when v_won then 'won' else 'lost' end
        where id = v_item.id;
      end if;

      select * into v_slip from public.bets where id = v_item.bet_id for update;
      if v_slip.status <> 'pending' then
        continue;
      end if;

      if exists (select 1 from public.bet_items where bet_id = v_slip.id and status = 'lost') then
        update public.bets set status = 'lost' where id = v_slip.id;
      elsif exists (select 1 from public.bet_items where bet_id = v_slip.id and status = 'pending') then
        v_product := 1;
        for v_leg in
          select odds, status from public.bet_items where bet_id = v_slip.id
        loop
          v_product := v_product * (case when v_leg.status = 'void' then 1 else v_leg.odds end);
        end loop;
        update public.bets
        set odds = round(v_product, 4),
            potential_payout = round(v_slip.bet_amount * v_product, 2)
        where id = v_slip.id;
      else
        select count(*), count(*) filter (where status = 'void')
          into v_legs, v_voids
        from public.bet_items
        where bet_id = v_slip.id;
        v_product := 1;
        for v_leg in
          select odds, status from public.bet_items where bet_id = v_slip.id
        loop
          v_product := v_product * (case when v_leg.status = 'void' then 1 else v_leg.odds end);
        end loop;
        v_payout := round(v_slip.bet_amount * v_product, 2);
        if v_voids = v_legs then
          update public.bets
          set status = 'void', odds = 1, potential_payout = v_slip.bet_amount
          where id = v_slip.id;
          update public.profiles
          set balance = balance + v_slip.bet_amount
          where id = v_slip.user_id;
        else
          update public.bets
          set status = 'won', odds = round(v_product, 4), potential_payout = v_payout
          where id = v_slip.id;
          update public.profiles
          set balance = balance + v_payout
          where id = v_slip.user_id;
        end if;
      end if;
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

create or replace function public.place_parlay(p_legs jsonb, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_amount numeric(12,2);
  v_balance numeric(14,2);
  v_bet_id bigint;
  v_count integer;
  v_distinct integer;
  v_found integer;
  v_product numeric := 1;
  v_payout numeric(14,2);
  v_game public.games%rowtype;
  v_selection text;
  v_price numeric(8,2);
  v_ids bigint[] := array[]::bigint[];
  v_selections text[] := array[]::text[];
  v_prices numeric[] := array[]::numeric[];
begin
  if v_uid is null then
    raise exception 'יש להתחבר';
  end if;
  if p_legs is null or jsonb_typeof(p_legs) <> 'array' then
    raise exception 'בחרו לפחות משחק אחד';
  end if;
  v_count := jsonb_array_length(p_legs);
  if v_count < 1 or v_count > 8 then
    raise exception 'אפשר בין משחק אחד ל־8 משחקים';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'סכום לא תקין';
  end if;
  v_amount := round(p_amount, 2);
  if v_amount <= 0 then
    raise exception 'סכום לא תקין';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_legs) as value
    where coalesce(value->>'game_id', '') !~ '^[0-9]+$'
       or coalesce(value->>'selection', '') not in ('1', 'X', '2')
  ) then
    raise exception 'בחירה לא תקינה';
  end if;

  select count(distinct (value->>'game_id')::bigint)
    into v_distinct
  from jsonb_array_elements(p_legs) as value;
  if v_distinct <> v_count then
    raise exception 'אי אפשר לבחור אותו משחק פעמיים';
  end if;

  select count(*) into v_found
  from public.games
  where id in (
    select (value->>'game_id')::bigint from jsonb_array_elements(p_legs) as value
  );
  if v_found <> v_count then
    raise exception 'המשחק לא נמצא';
  end if;

  for v_game in
    select * from public.games
    where id in (
      select (value->>'game_id')::bigint from jsonb_array_elements(p_legs) as value
    )
    order by id
    for update
  loop
    select value->>'selection' into v_selection
    from jsonb_array_elements(p_legs) as value
    where (value->>'game_id')::bigint = v_game.id;

    if v_game.status <> 'upcoming'
       or v_game.match_time is null
       or v_game.match_time <= now() + interval '5 minutes' then
      raise exception 'ההימור נעול — נותרו פחות מ־5 דקות לתחילת המשחק';
    end if;

    v_price := case v_selection
      when '1' then v_game.home_odds
      when 'X' then v_game.draw_odds
      else v_game.away_odds
    end;
    if v_price is null or v_price < 1.01 then
      raise exception 'היחס לא זמין';
    end if;

    v_product := v_product * v_price;
    v_ids := array_append(v_ids, v_game.id);
    v_selections := array_append(v_selections, v_selection);
    v_prices := array_append(v_prices, v_price);
  end loop;

  if v_amount * v_product > 99999999.99 then
    raise exception 'הסכום חורג מהתקרה';
  end if;
  v_payout := round(v_amount * v_product, 2);

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

  insert into public.bets (
    user_id, game_id, bet_selection, bet_amount, odds, potential_payout, status
  ) values (
    v_uid,
    case when v_count = 1 then v_ids[1] else null end,
    case when v_count = 1 then v_selections[1] else null end,
    v_amount,
    round(v_product, 4),
    v_payout,
    'pending'
  )
  returning id into v_bet_id;

  insert into public.bet_items (bet_id, game_id, bet_selection, odds)
  select v_bet_id, x.game_id, x.selection, x.odds
  from unnest(v_ids, v_selections, v_prices) as x(game_id, selection, odds);

  select balance into v_balance from public.profiles where id = v_uid;
  return jsonb_build_object(
    'bet_id', v_bet_id,
    'legs', v_count,
    'odds', round(v_product, 4),
    'potential_payout', v_payout,
    'balance', v_balance
  );
end;
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
  if v_bet.game_id is null or (select count(*) from public.bet_items where bet_id = v_bet.id) > 1 then
    raise exception 'אי אפשר לערוך טופס משולב';
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

  update public.bets
  set bet_selection = p_selection,
      bet_amount = v_amount,
      odds = v_odds,
      potential_payout = v_payout
  where id = v_bet.id;
  update public.bet_items
  set bet_selection = p_selection,
      odds = v_odds
  where bet_id = v_bet.id;

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

create or replace function public.cancel_bet(p_bet_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_bet public.bets%rowtype;
  v_game public.games%rowtype;
  v_balance numeric(10,2);
begin
  if v_uid is null then
    raise exception 'יש להתחבר';
  end if;

  select * into v_bet
  from public.bets
  where id = p_bet_id and user_id = v_uid
  for update;
  if not found then
    raise exception 'ההימור לא נמצא';
  end if;
  if v_bet.status <> 'pending' then
    raise exception 'אפשר לבטל רק הימור ממתין';
  end if;

  if exists (select 1 from public.bet_items where bet_id = v_bet.id) then
    if exists (
      select 1
      from public.bet_items i
      join public.games g on g.id = i.game_id
      where i.bet_id = v_bet.id
        and (g.status <> 'upcoming' or g.match_time is null or g.match_time <= now())
    ) then
      raise exception 'אפשר לבטל רק לפני תחילת המשחקים';
    end if;
    perform g.id
    from public.games g
    join public.bet_items i on i.game_id = g.id
    where i.bet_id = v_bet.id
    order by g.id
    for update;
  else
    select * into v_game
    from public.games
    where id = v_bet.game_id
    for update;
    if not found then
      raise exception 'המשחק לא נמצא';
    end if;
    if v_game.status <> 'upcoming' or v_game.match_time is null or v_game.match_time <= now() then
      raise exception 'אפשר לבטל רק לפני תחילת המשחק';
    end if;
  end if;

  update public.profiles
  set balance = balance + v_bet.bet_amount
  where id = v_uid;

  update public.bets
  set status = 'cancelled'
  where id = v_bet.id;

  select balance into v_balance from public.profiles where id = v_uid;
  return jsonb_build_object(
    'bet_id', v_bet.id,
    'status', 'cancelled',
    'refund', v_bet.bet_amount,
    'balance', v_balance
  );
end;
$$;

revoke all on function public.place_parlay(jsonb, numeric) from public, anon, authenticated;
grant execute on function public.place_parlay(jsonb, numeric) to authenticated;
notify pgrst, 'reload schema';
