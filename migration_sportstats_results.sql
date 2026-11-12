-- Safely settle only games already matched to SportStatsAPI by its text match code.
-- Does not modify Winner odds, odds_locked, legacy fixture_id, or game IDs.
create or replace function public.sync_sportstats_result(
  p_match_code text,
  p_home_score integer,
  p_away_score integer
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
  if coalesce(trim(p_match_code),'') = ''
     or p_home_score is null or p_away_score is null
     or p_home_score < 0 or p_away_score < 0 then
    raise exception 'Invalid SportStatsAPI result payload';
  end if;

  select * into v_game
  from public.games
  where sportstats_match_code = p_match_code
  for update;

  if not found then
    return jsonb_build_object('matched',false,'match_code',p_match_code);
  end if;

  if coalesce(v_game.result_confirmed,false) or v_game.status in ('finished','cancelled') then
    return jsonb_build_object('matched',true,'already_confirmed',true,'game_id',v_game.id,
      'status',v_game.status,'home_score',v_game.home_score,'away_score',v_game.away_score,'settled',0);
  end if;

  update public.games
  set home_score = p_home_score,
      away_score = p_away_score,
      status = 'finished',
      result_confirmed = true
  where id = v_game.id
  returning * into v_game;

  -- Settle straight bets, excluding parlay slips (their legs are handled below).
  for v_bet in
    select * from public.bets
    where game_id = v_game.id and status = 'pending'
      and not exists (select 1 from public.bet_items i where i.bet_id = bets.id)
    order by id
    for update
  loop
    v_won := (v_bet.bet_selection = '1' and v_game.home_score > v_game.away_score)
      or (v_bet.bet_selection = 'X' and v_game.home_score = v_game.away_score)
      or (v_bet.bet_selection = '2' and v_game.home_score < v_game.away_score);
    if v_won then
      update public.bets set status = 'won' where id = v_bet.id;
      update public.profiles set balance = balance + v_bet.potential_payout where id = v_bet.user_id;
    else
      update public.bets set status = 'lost' where id = v_bet.id;
    end if;
    v_settled := v_settled + 1;
  end loop;

  -- Settle each pending parlay leg, then settle/reprice its parent slip atomically.
  for v_item in
    select i.*
    from public.bet_items i
    join public.bets b on b.id = i.bet_id
    where i.game_id = v_game.id and i.status = 'pending' and b.status = 'pending'
    order by i.id
    for update of i
  loop
    v_won := (v_item.bet_selection = '1' and v_game.home_score > v_game.away_score)
      or (v_item.bet_selection = 'X' and v_game.home_score = v_game.away_score)
      or (v_item.bet_selection = '2' and v_game.home_score < v_game.away_score);
    update public.bet_items set status = case when v_won then 'won' else 'lost' end
    where id = v_item.id;

    select * into v_slip from public.bets where id = v_item.bet_id for update;
    if v_slip.status <> 'pending' then
      continue;
    end if;

    if exists (select 1 from public.bet_items where bet_id = v_slip.id and status = 'lost') then
      update public.bets set status = 'lost' where id = v_slip.id;
    elsif exists (select 1 from public.bet_items where bet_id = v_slip.id and status = 'pending') then
      v_product := 1;
      for v_leg in select odds,status from public.bet_items where bet_id = v_slip.id loop
        v_product := v_product * (case when v_leg.status = 'void' then 1 else v_leg.odds end);
      end loop;
      update public.bets set odds = round(v_product,4),
        potential_payout = round(v_slip.bet_amount * v_product,2)
      where id = v_slip.id;
    else
      select count(*),count(*) filter (where status='void') into v_legs,v_voids
      from public.bet_items where bet_id = v_slip.id;
      v_product := 1;
      for v_leg in select odds,status from public.bet_items where bet_id = v_slip.id loop
        v_product := v_product * (case when v_leg.status = 'void' then 1 else v_leg.odds end);
      end loop;
      v_payout := round(v_slip.bet_amount * v_product,2);
      if v_voids = v_legs then
        update public.bets set status='void',odds=1,potential_payout=v_slip.bet_amount where id=v_slip.id;
        update public.profiles set balance=balance + v_slip.bet_amount where id=v_slip.user_id;
      else
        update public.bets set status='won',odds=round(v_product,4),potential_payout=v_payout where id=v_slip.id;
        update public.profiles set balance=balance + v_payout where id=v_slip.user_id;
      end if;
    end if;
    v_settled := v_settled + 1;
  end loop;

  return jsonb_build_object('matched',true,'already_confirmed',false,'game_id',v_game.id,
    'match_code',p_match_code,'status',v_game.status,'home_score',v_game.home_score,
    'away_score',v_game.away_score,'settled',v_settled);
end;
$$;

revoke all on function public.sync_sportstats_result(text,integer,integer) from public,anon,authenticated;
grant execute on function public.sync_sportstats_result(text,integer,integer) to service_role;
