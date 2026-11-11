-- Winner odds import. Run once in Supabase SQL Editor.
-- Only authenticated users may import odds; no service-role key is exposed to the extension.
create or replace function public.import_winner_odds(p_matches jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  item jsonb;
  v_home text;
  v_away text;
  v_kickoff timestamptz;
  v_home_odds numeric;
  v_draw_odds numeric;
  v_away_odds numeric;
  v_updated integer := 0;
  v_rows integer := 0;
begin
  if auth.uid() is null then
    raise exception 'authentication required';
  end if;
  if jsonb_typeof(p_matches) <> 'array' then
    raise exception 'matches must be an array';
  end if;

  for item in select value from jsonb_array_elements(p_matches)
  loop
    v_home := nullif(trim(item->>'home_team'), '');
    v_away := nullif(trim(item->>'away_team'), '');
    v_kickoff := nullif(item->>'kickoff', '')::timestamptz;
    v_home_odds := nullif(item->>'home_odds', '')::numeric;
    v_draw_odds := nullif(item->>'draw_odds', '')::numeric;
    v_away_odds := nullif(item->>'away_odds', '')::numeric;

    if v_home is null or v_away is null or v_kickoff is null
       or v_home_odds not between 1.01 and 99.99
       or v_draw_odds not between 1.01 and 99.99
       or v_away_odds not between 1.01 and 99.99 then
      continue;
    end if;

    update public.games
       set home_odds = v_home_odds,
           draw_odds = v_draw_odds,
           away_odds = v_away_odds,
           odds_locked = true
     where lower(trim(home_team)) = lower(v_home)
       and lower(trim(away_team)) = lower(v_away)
       and abs(extract(epoch from (match_time - v_kickoff))) <= 1200
       and status = 'upcoming'
       and match_time > now() + interval '5 minutes'
       and coalesce(result_confirmed, false) = false;

    get diagnostics v_rows = row_count;
    v_updated := v_updated + v_rows;
  end loop;
  return jsonb_build_object('updated', v_updated);
end;
$$;

revoke all on function public.import_winner_odds(jsonb) from public, anon;
grant execute on function public.import_winner_odds(jsonb) to authenticated;
