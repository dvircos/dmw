-- Make Winner 1X2 ingestion resilient to Hebrew/English team labels and
-- small kickoff-time discrepancies. Team matching remains pair-specific.
begin;

create or replace function public.winner_team_match_key(p_name text)
returns text
language sql
immutable
parallel safe
set search_path = public
as $function$
  with normalized as (
    select regexp_replace(
      translate(lower(coalesce(p_name,'')),
        'áàäâãåæçéèëêíìïîñóòöôõøúùüûýÿß',
        'aaaaaaaceeeeiiiinoooooouuuuyys'),
      '[^a-z0-9א-ת]', '', 'g'
    ) as k
  )
  select case
    when k in ('לאסק','lask','lasklinz') then 'lask'
    when k in ('בודוגלימט','bodoglimt','fkbodoglimt') then 'bodoglimt'
    when k in ('פסוואיינדהובן','פסו','psv','psveindhoven') then 'psv'
    when k in ('ריאלמדריד','realmadrid') then 'realmadrid'
    else k
  end
  from normalized
$function$;

create or replace function public.import_winner_odds(p_matches jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  item jsonb;
  v_home_key text;
  v_away_key text;
  v_kickoff timestamptz;
  v_home_odds numeric;
  v_draw_odds numeric;
  v_away_odds numeric;
  v_updated integer := 0;
  v_rows integer := 0;
  v_received integer := 0;
  v_valid integer := 0;
  v_matched integer := 0;
  v_unmatched integer := 0;
begin
  if not public.admin_is_admin() then
    raise exception 'אין הרשאת מנהל';
  end if;
  if jsonb_typeof(p_matches) <> 'array' then
    raise exception 'matches must be an array';
  end if;
  v_received := jsonb_array_length(p_matches);
  if v_received > 500 then
    raise exception 'too many matches in one import';
  end if;

  for item in select value from jsonb_array_elements(p_matches)
  loop
    begin
      v_home_key := public.winner_team_match_key(item->>'home_team');
      v_away_key := public.winner_team_match_key(item->>'away_team');
      v_kickoff := nullif(item->>'kickoff', '')::timestamptz;
      v_home_odds := nullif(item->>'home_odds', '')::numeric;
      v_draw_odds := nullif(item->>'draw_odds', '')::numeric;
      v_away_odds := nullif(item->>'away_odds', '')::numeric;
    exception when others then
      continue;
    end;

    if coalesce(v_home_key,'') = '' or coalesce(v_away_key,'') = ''
       or v_kickoff is null
       or v_home_odds is null or v_draw_odds is null or v_away_odds is null
       or v_home_odds not between 1.01 and 99.99
       or v_draw_odds not between 1.01 and 99.99
       or v_away_odds not between 1.01 and 99.99 then
      continue;
    end if;
    v_valid := v_valid + 1;

    update public.games g
       set home_odds = v_home_odds,
           draw_odds = v_draw_odds,
           away_odds = v_away_odds,
           odds_locked = true
     where public.winner_team_match_key(g.home_team) = v_home_key
       and public.winner_team_match_key(g.away_team) = v_away_key
       and abs(extract(epoch from (g.match_time - v_kickoff))) <= 5400
       and g.status = 'upcoming'
       and g.match_time > now() + interval '5 minutes'
       and coalesce(g.result_confirmed, false) = false;

    get diagnostics v_rows = row_count;
    if v_rows > 0 then
      v_matched := v_matched + 1;
      v_updated := v_updated + v_rows;
    else
      v_unmatched := v_unmatched + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'received', v_received,
    'processed', v_valid,
    'matched', v_matched,
    'updated', v_updated,
    'unmatched', v_unmatched
  );
end;
$function$;

revoke all on function public.winner_team_match_key(text) from public, anon;
grant execute on function public.winner_team_match_key(text) to authenticated;
revoke all on function public.import_winner_odds(jsonb) from public, anon;
grant execute on function public.import_winner_odds(jsonb) to authenticated;

notify pgrst, 'reload schema';
commit;
