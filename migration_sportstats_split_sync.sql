-- SportStatsAPI fixture identity is separate from legacy fixture_id and API-Football IDs.
-- Safe to apply without changing existing bets, Winner odds, or game primary keys.
alter table public.games
  add column if not exists sportstats_match_code text,
  add column if not exists sportstats_league_code text,
  add column if not exists sportstats_league_name text,
  add column if not exists sportstats_home_team_code text,
  add column if not exists sportstats_away_team_code text,
  add column if not exists sportstats_api_home_name text,
  add column if not exists sportstats_api_away_name text;

create unique index if not exists games_sportstats_match_code_uidx
  on public.games(sportstats_match_code)
  where sportstats_match_code is not null;

create or replace function public.upsert_sportstats_fixture(
  p_match_code text,
  p_league_code text,
  p_league_name text,
  p_home_team_code text,
  p_away_team_code text,
  p_api_home_name text,
  p_api_away_name text,
  p_home_team text,
  p_away_team text,
  p_home_flag text,
  p_away_flag text,
  p_match_time timestamptz,
  p_round_name text
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_game public.games%rowtype;
  v_created boolean := false;
  v_matches integer;
  v_matched boolean := false;
begin
  if coalesce(trim(p_match_code),'') = ''
     or coalesce(trim(p_league_code),'') = ''
     or coalesce(trim(p_home_team_code),'') = ''
     or coalesce(trim(p_away_team_code),'') = ''
     or coalesce(trim(p_api_home_name),'') = ''
     or coalesce(trim(p_api_away_name),'') = ''
     or coalesce(trim(p_home_team),'') = ''
     or coalesce(trim(p_away_team),'') = ''
     or p_match_time is null then
    raise exception 'Incomplete SportStatsAPI fixture';
  end if;

  -- Provider IDs are opaque text. Never cast them into fixture_id.
  select * into v_game
  from public.games
  where sportstats_match_code = p_match_code
  for update;

  if not found then
    -- Reconcile only a unique, exact normalized home/away pair within 20 minutes.
    -- Ambiguous or unmatched fixtures are inserted separately, never guessed.
    select count(*) into v_matches
    from public.games g
    where lower(trim(g.home_team)) = lower(trim(p_home_team))
      and lower(trim(g.away_team)) = lower(trim(p_away_team))
      and abs(extract(epoch from (g.match_time - p_match_time))) <= 1200
      and g.status = 'upcoming'
      and coalesce(g.result_confirmed,false) = false
      and g.sportstats_match_code is null;

    if v_matches = 1 then
      select * into v_game
      from public.games g
      where lower(trim(g.home_team)) = lower(trim(p_home_team))
        and lower(trim(g.away_team)) = lower(trim(p_away_team))
        and abs(extract(epoch from (g.match_time - p_match_time))) <= 1200
        and g.status = 'upcoming'
        and coalesce(g.result_confirmed,false) = false
        and g.sportstats_match_code is null
      limit 1
      for update;
      v_matched := found;
    end if;

    if v_matched then
      update public.games
      set sportstats_match_code = p_match_code,
          sportstats_league_code = p_league_code,
          sportstats_league_name = p_league_name,
          sportstats_home_team_code = p_home_team_code,
          sportstats_away_team_code = p_away_team_code,
          sportstats_api_home_name = p_api_home_name,
          sportstats_api_away_name = p_api_away_name,
          home_flag = coalesce(p_home_flag,home_flag),
          away_flag = coalesce(p_away_flag,away_flag)
      where id = v_game.id
      returning * into v_game;
    else
      insert into public.games (
        sportstats_match_code, sportstats_league_code, sportstats_league_name,
        sportstats_home_team_code, sportstats_away_team_code,
        sportstats_api_home_name, sportstats_api_away_name,
        home_team, away_team, home_flag, away_flag, match_time,
        round_name, status, result_confirmed
      ) values (
        p_match_code, p_league_code, p_league_name,
        p_home_team_code, p_away_team_code,
        p_api_home_name, p_api_away_name,
        p_home_team, p_away_team, p_home_flag, p_away_flag, p_match_time,
        p_round_name, 'upcoming', false
      )
      returning * into v_game;
      v_created := true;
    end if;
  else
    -- Metadata refresh only: no odds, scores, status, result or legacy IDs touched.
    update public.games
    set sportstats_league_code = p_league_code,
        sportstats_league_name = p_league_name,
        sportstats_home_team_code = p_home_team_code,
        sportstats_away_team_code = p_away_team_code,
        sportstats_api_home_name = p_api_home_name,
        sportstats_api_away_name = p_api_away_name,
        home_flag = coalesce(p_home_flag,home_flag),
        away_flag = coalesce(p_away_flag,away_flag)
    where id = v_game.id
    returning * into v_game;
  end if;

  return jsonb_build_object(
    'game_id',v_game.id,'sportstats_match_code',p_match_code,
    'created',v_created,'status',v_game.status
  );
end;
$$;

revoke all on function public.upsert_sportstats_fixture(text,text,text,text,text,text,text,text,text,text,text,timestamptz,text)
  from public, anon, authenticated;
grant execute on function public.upsert_sportstats_fixture(text,text,text,text,text,text,text,text,text,text,text,timestamptz,text)
  to service_role;
