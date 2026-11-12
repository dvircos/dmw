-- Correct the fixture mapper for existing rows created by the legacy provider.
-- Older rows have a plain competition round name (no provider prefix).
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

  select * into v_game from public.games
  where api_football_fixture_id = p_api_fixture_id
  for update;

  if not found then
    select * into v_game
    from public.games
    where lower(trim(home_team)) in (lower(trim(p_home_team)), lower(trim(p_api_home_name)))
      and lower(trim(away_team)) in (lower(trim(p_away_team)), lower(trim(p_api_away_name)))
      and abs(extract(epoch from (match_time - p_match_time))) <= 2592000
      and (
        split_part(coalesce(round_name, ''), '|', 1) = split_part(coalesce(p_round_name, ''), '|', 1)
        or (position('|' in coalesce(round_name, '')) = 0
            and abs(extract(epoch from (match_time - p_match_time))) <= 86400)
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