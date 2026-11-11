-- Allow unlimited separate bets on the same game:
-- single bets, multiple selections, and multiple different parlays can all include a fixture.
-- A game may still appear only once inside a single parlay slip.

drop index if exists public.bets_one_slip_per_selection;

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

    -- Repeated bets on the same fixture are allowed across separate slips.

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

  -- Duplicate selections across separate bets are allowed.

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
    update public.bet_items
    set bet_selection = p_selection,
        odds = v_odds
    where bet_id = v_bet.id;
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

revoke all on function public.place_parlay(jsonb, numeric) from public, anon, authenticated;
grant execute on function public.place_parlay(jsonb, numeric) to authenticated;

revoke all on function public.edit_bet(bigint, text, numeric) from public, anon, authenticated;
grant execute on function public.edit_bet(bigint, text, numeric) to authenticated;

notify pgrst, 'reload schema';
