-- API-Football split sync: preserve internal game IDs and existing bets.
alter table public.games
  add column if not exists api_football_fixture_id bigint,
  add column if not exists api_home_team_name text,
  add column if not exists api_away_team_name text;

create unique index if not exists games_api_football_fixture_id_uidx
  on public.games(api_football_fixture_id)
  where api_football_fixture_id is not null;

create or replace function public.upsert_api_football_fixture(
  p_api_fixture_id bigint,
  p_api_home_name text,
  p_api_away_name text,
  p_home_team text,
  p_away_team text,
  p_home_flag text,
  p_away_flag text,
  p_match_time timestamptz,
  p_round_name text
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  v_game public.games%rowtype;
  v_created boolean := false;
begin
  if p_api_fixture_id is null or p_api_home_name is null or p_api_away_name is null
     or p_home_team is null or p_away_team is null or p_match_time is null then
    raise exception 'Incomplete API-Football fixture';
  end if;

  select * into v_game
  from public.games
  where api_football_fixture_id = p_api_fixture_id
  for update;

  if not found then
    -- Reconcile an older provider's row by teams + kickoff, keeping games.id
    -- (and therefore every existing bet/bet_item foreign key) unchanged.
    select * into v_game
    from public.games
    where lower(trim(home_team)) in (lower(trim(p_home_team)), lower(trim(p_api_home_name)))
      and lower(trim(away_team)) in (lower(trim(p_away_team)), lower(trim(p_api_away_name)))
      and abs(extract(epoch from (match_time - p_match_time))) <= 2592000
      and (
        split_part(coalesce(round_name, ''), '|', 1) = split_part(p_round_name, '|', 1)
        or (round_name is null and abs(extract(epoch from (match_time - p_match_time))) <= 86400)
      )
      and status in ('upcoming','live')
      and coalesce(result_confirmed,false) = false
      and (api_football_fixture_id is null or api_football_fixture_id = p_api_fixture_id)
    order by abs(extract(epoch from (match_time - p_match_time)))
    limit 1
    for update;

    if found then
      update public.games
      set api_football_fixture_id = p_api_fixture_id,
          api_home_team_name = p_api_home_name,
          api_away_team_name = p_api_away_name,
          home_team = p_home_team,
          away_team = p_away_team,
          home_flag = coalesce(p_home_flag, home_flag),
          away_flag = coalesce(p_away_flag, away_flag),
          match_time = p_match_time,
          round_name = coalesce(p_round_name, round_name)
      where id = v_game.id
      returning * into v_game;
    else
      insert into public.games (
        api_football_fixture_id, api_home_team_name, api_away_team_name, home_team, away_team, home_flag, away_flag,
        match_time, round_name, status, home_score, away_score, result_confirmed
      ) values (
        p_api_fixture_id, p_api_home_name, p_api_away_name, p_home_team, p_away_team, p_home_flag, p_away_flag,
        p_match_time, p_round_name, 'upcoming', 0, 0, false
      ) returning * into v_game;
      v_created := true;
    end if;
  else
    if not coalesce(v_game.result_confirmed,false) then
    update public.games
    set api_home_team_name = p_api_home_name,
        api_away_team_name = p_api_away_name,
        home_team = p_home_team,
        away_team = p_away_team,
        home_flag = coalesce(p_home_flag, home_flag),
        away_flag = coalesce(p_away_flag, away_flag),
        match_time = p_match_time,
        round_name = coalesce(p_round_name, round_name)
    where id = v_game.id
      and coalesce(result_confirmed, false) = false
    returning * into v_game;
    end if;
  end if;

  return jsonb_build_object('game_id', v_game.id, 'api_fixture_id', p_api_fixture_id,
                            'created', v_created, 'status', v_game.status);
end;
$$;

create or replace function public.sync_api_football_result(
  p_api_fixture_id bigint,
  p_status text,
  p_home_score integer,
  p_away_score integer
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  v_game public.games%rowtype;
  v_bet record;
  v_item record;
  v_slip public.bets%rowtype;
  v_leg record;
  v_won boolean;
  v_product numeric;
  v_payout numeric(14,2);
  v_legs integer;
  v_voids integer;
  v_settled integer := 0;
begin
  if p_status is null or p_status not in ('finished','cancelled') then
    raise exception 'Only final results can be settled';
  end if;
  if p_status = 'finished' and (p_home_score is null or p_away_score is null
      or p_home_score < 0 or p_away_score < 0) then
    raise exception 'Invalid final score';
  end if;

  select * into v_game
  from public.games
  where api_football_fixture_id = p_api_fixture_id
  for update;

  if not found then
    raise exception 'API-Football fixture is not mapped to an app game';
  end if;

  if coalesce(v_game.result_confirmed,false) or v_game.status in ('finished','cancelled') then
    return jsonb_build_object('fixture_id',p_api_fixture_id,'game_id',v_game.id,
      'status',v_game.status,'settled',0,'already_confirmed',true);
  end if;

  update public.games
  set status = p_status,
      home_score = case when p_status='finished' then p_home_score else 0 end,
      away_score = case when p_status='finished' then p_away_score else 0 end,
      result_confirmed = true
  where id = v_game.id
  returning * into v_game;

  -- Straight bets only (parlays are represented by bet_items).
  for v_bet in
    select * from public.bets
    where game_id=v_game.id and status='pending'
      and not exists(select 1 from public.bet_items i where i.bet_id=bets.id)
    order by id for update
  loop
    if p_status='cancelled' then
      update public.bets set status='void' where id=v_bet.id;
      update public.profiles set balance=balance+v_bet.bet_amount where id=v_bet.user_id;
    else
      v_won := (v_bet.bet_selection='1' and p_home_score>p_away_score)
        or (v_bet.bet_selection='X' and p_home_score=p_away_score)
        or (v_bet.bet_selection='2' and p_home_score<p_away_score);
      if v_won then
        update public.bets set status='won' where id=v_bet.id;
        update public.profiles set balance=balance+v_bet.potential_payout where id=v_bet.user_id;
      else
        update public.bets set status='lost' where id=v_bet.id;
      end if;
    end if;
    v_settled:=v_settled+1;
  end loop;

  -- Update each affected parlay leg, then settle/refund the parent exactly once.
  for v_item in
    select i.* from public.bet_items i
    join public.bets b on b.id=i.bet_id
    where i.game_id=v_game.id and i.status='pending' and b.status='pending'
    order by i.id for update of i
  loop
    if p_status='cancelled' then
      update public.bet_items set status='void' where id=v_item.id;
    else
      v_won := (v_item.bet_selection='1' and p_home_score>p_away_score)
        or (v_item.bet_selection='X' and p_home_score=p_away_score)
        or (v_item.bet_selection='2' and p_home_score<p_away_score);
      update public.bet_items set status=case when v_won then 'won' else 'lost' end
      where id=v_item.id;
    end if;

    select * into v_slip from public.bets where id=v_item.bet_id for update;
    if v_slip.status<>'pending' then continue; end if;

    if exists(select 1 from public.bet_items where bet_id=v_slip.id and status='lost') then
      update public.bets set status='lost' where id=v_slip.id;
    elsif exists(select 1 from public.bet_items where bet_id=v_slip.id and status='pending') then
      v_product:=1;
      for v_leg in select odds,status from public.bet_items where bet_id=v_slip.id loop
        v_product:=v_product*(case when v_leg.status='void' then 1 else v_leg.odds end);
      end loop;
      update public.bets set odds=round(v_product,4),
        potential_payout=round(v_slip.bet_amount*v_product,2) where id=v_slip.id;
    else
      select count(*),count(*) filter(where status='void') into v_legs,v_voids
      from public.bet_items where bet_id=v_slip.id;
      v_product:=1;
      for v_leg in select odds,status from public.bet_items where bet_id=v_slip.id loop
        v_product:=v_product*(case when v_leg.status='void' then 1 else v_leg.odds end);
      end loop;
      v_payout:=round(v_slip.bet_amount*v_product,2);
      if v_voids=v_legs then
        update public.bets set status='void',odds=1,potential_payout=v_slip.bet_amount
        where id=v_slip.id;
        update public.profiles set balance=balance+v_slip.bet_amount where id=v_slip.user_id;
      else
        update public.bets set status='won',odds=round(v_product,4),potential_payout=v_payout
        where id=v_slip.id;
        update public.profiles set balance=balance+v_payout where id=v_slip.user_id;
      end if;
    end if;
    v_settled:=v_settled+1;
  end loop;

  return jsonb_build_object('fixture_id',p_api_fixture_id,'game_id',v_game.id,
    'status',v_game.status,'home_score',v_game.home_score,'away_score',v_game.away_score,
    'settled',v_settled);
end;
$$;

create or replace function public.sync_api_football_live(
  p_api_fixture_id bigint,
  p_home_score integer,
  p_away_score integer
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare v_game public.games%rowtype;
begin
  if p_home_score is not null and p_home_score < 0 or p_away_score is not null and p_away_score < 0 then
    raise exception 'Invalid live score';
  end if;
  select * into v_game from public.games
  where api_football_fixture_id=p_api_fixture_id for update;
  if not found then raise exception 'API-Football fixture is not mapped to an app game'; end if;
  if coalesce(v_game.result_confirmed,false) or v_game.status in ('finished','cancelled') then
    return jsonb_build_object('fixture_id',p_api_fixture_id,'game_id',v_game.id,'status',v_game.status,'ignored',true);
  end if;
  update public.games set status='live',
    home_score=coalesce(p_home_score,home_score),
    away_score=coalesce(p_away_score,away_score)
  where id=v_game.id returning * into v_game;
  return jsonb_build_object('fixture_id',p_api_fixture_id,'game_id',v_game.id,
    'status',v_game.status,'home_score',v_game.home_score,'away_score',v_game.away_score);
end;
$$;

revoke all on function public.upsert_api_football_fixture(bigint,text,text,text,text,text,text,timestamptz,text) from public,anon,authenticated;
revoke all on function public.sync_api_football_result(bigint,text,integer,integer) from public,anon,authenticated;
revoke all on function public.sync_api_football_live(bigint,integer,integer) from public,anon,authenticated;
grant execute on function public.upsert_api_football_fixture(bigint,text,text,text,text,text,text,timestamptz,text) to service_role;
grant execute on function public.sync_api_football_result(bigint,text,integer,integer) to service_role;
grant execute on function public.sync_api_football_live(bigint,integer,integer) to service_role;
notify pgrst, 'reload schema';
