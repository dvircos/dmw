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


create table if not exists public.winner_odds_import_runs (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  received integer not null default 0,
  processed integer not null default 0,
  matched integer not null default 0,
  updated integer not null default 0,
  unmatched integer not null default 0,
  unmatched_samples jsonb not null default '[]'::jsonb
);
alter table public.winner_odds_import_runs enable row level security;
revoke all on public.winner_odds_import_runs from public, anon, authenticated;

create or replace function public.import_winner_odds(p_matches jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  item jsonb;
  v_home text;
  v_away text;
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
  v_unmatched_samples jsonb := '[]'::jsonb;
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
      v_home := nullif(trim(item->>'home_team'), '');
      v_away := nullif(trim(item->>'away_team'), '');
      v_home_key := public.winner_team_match_key(v_home);
      v_away_key := public.winner_team_match_key(v_away);
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
     where (
          public.winner_team_match_key(g.home_team) = v_home_key
          or public.winner_team_match_key(g.sportstats_api_home_name) = v_home_key
          or public.winner_team_match_key(g.api_home_team_name) = v_home_key
       )
       and (
          public.winner_team_match_key(g.away_team) = v_away_key
          or public.winner_team_match_key(g.sportstats_api_away_name) = v_away_key
          or public.winner_team_match_key(g.api_away_team_name) = v_away_key
       )
       and abs(extract(epoch from (g.match_time - v_kickoff))) <= 10800
       and g.status = 'upcoming'
       and g.match_time > now() + interval '5 minutes'
       and coalesce(g.result_confirmed, false) = false;

    get diagnostics v_rows = row_count;
    if v_rows > 0 then
      v_matched := v_matched + 1;
      v_updated := v_updated + v_rows;
    else
      v_unmatched := v_unmatched + 1;
      if jsonb_array_length(v_unmatched_samples) < 10 then
        v_unmatched_samples := v_unmatched_samples || jsonb_build_array(jsonb_build_object(
          'home_team', v_home, 'away_team', v_away, 'kickoff', v_kickoff,
          'home_odds', v_home_odds, 'draw_odds', v_draw_odds, 'away_odds', v_away_odds
        ));
      end if;
    end if;
  end loop;

  insert into public.winner_odds_import_runs(received,processed,matched,updated,unmatched,unmatched_samples)
  values(v_received,v_valid,v_matched,v_updated,v_unmatched,v_unmatched_samples);

  return jsonb_build_object(
    'received', v_received,
    'processed', v_valid,
    'matched', v_matched,
    'updated', v_updated,
    'unmatched', v_unmatched
  );
end;
$function$;

revoke all on function public.import_winner_odds(jsonb) from public, anon;
grant execute on function public.import_winner_odds(jsonb) to authenticated;
notify pgrst, 'reload schema';

revoke all on function public.winner_team_match_key(text) from public, anon;
grant execute on function public.winner_team_match_key(text) to authenticated;
revoke all on function public.import_winner_odds(jsonb) from public, anon;
grant execute on function public.import_winner_odds(jsonb) to authenticated;

notify pgrst, 'reload schema';
commit;


-- Follow-up hardening: cover additional Winner labels and retain unmatched
-- events in the app's active fixture window for actionable diagnostics.
create or replace function public.winner_team_match_key(p_name text)
returns text language sql immutable parallel safe set search_path=public as $$
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
    when k in ('בודוגלימט','בודו','גלימט','bodoglimt','fkbodoglimt','bodo','glimt') then 'bodoglimt'
    when k in ('פסוואיינדהובן','פסו','psv','psveindhoven','איינדהובן') then 'psv'
    when k in ('ריאלמדריד','ריאל','realmadrid','real') then 'realmadrid'
    when k in ('רבלייפציג','לייפציג','rbleipzig','rasenballsportleipzig') then 'rbleipzig'
    when k in ('לאנס','lens') then 'lens'
    when k in ('סלובןברטיסלבה','סלובן','slovanbratislava','slovan') then 'slovanbratislava'
    when k in ('בטיס','betis','realbetis') then 'betis'
    when k in ('סבאחבאקו','סבאח','sabafc','sabahfc') then 'sabahfc'
    when k in ('שחטארדונצק','שחטאר','shakhtardonetsk','shakhtar') then 'shakhtardonetsk'
    when k in ('פנרבחצה','fenerbahce') then 'fenerbahce'
    when k in ('ליל','lille') then 'lille'
    when k in ('באיירןמינכן','באיירן','bayernmunich','bayern') then 'bayernmunich'
    when k in ('פריזסןזמן','פריז','psg','parissaintgermain') then 'psg'
    when k in ('רומא','asroma','roma') then 'asroma'
    else k
  end from normalized
$$;

create or replace function public.import_winner_odds(p_matches jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  item jsonb; v_home text; v_away text; v_home_key text; v_away_key text;
  v_kickoff timestamptz; v_home_odds numeric; v_draw_odds numeric; v_away_odds numeric;
  v_updated integer:=0; v_rows integer:=0; v_received integer:=0; v_valid integer:=0;
  v_matched integer:=0; v_unmatched integer:=0; v_unmatched_samples jsonb:='[]'::jsonb;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  if jsonb_typeof(p_matches)<>'array' then raise exception 'matches must be an array'; end if;
  v_received:=jsonb_array_length(p_matches);
  if v_received>500 then raise exception 'too many matches in one import'; end if;
  for item in select value from jsonb_array_elements(p_matches) loop
    begin
      v_home:=nullif(trim(item->>'home_team'),''); v_away:=nullif(trim(item->>'away_team'),'');
      v_home_key:=public.winner_team_match_key(v_home); v_away_key:=public.winner_team_match_key(v_away);
      v_kickoff:=nullif(item->>'kickoff','')::timestamptz;
      v_home_odds:=nullif(item->>'home_odds','')::numeric;
      v_draw_odds:=nullif(item->>'draw_odds','')::numeric;
      v_away_odds:=nullif(item->>'away_odds','')::numeric;
    exception when others then continue; end;
    if coalesce(v_home_key,'')='' or coalesce(v_away_key,'')='' or v_kickoff is null
      or v_home_odds is null or v_draw_odds is null or v_away_odds is null
      or v_home_odds not between 1.01 and 99.99 or v_draw_odds not between 1.01 and 99.99
      or v_away_odds not between 1.01 and 99.99 then continue; end if;
    v_valid:=v_valid+1;
    update public.games g set home_odds=v_home_odds,draw_odds=v_draw_odds,away_odds=v_away_odds,odds_locked=true
    where (
      public.winner_team_match_key(g.home_team)=v_home_key or
      public.winner_team_match_key(g.sportstats_api_home_name)=v_home_key or
      public.winner_team_match_key(g.api_home_team_name)=v_home_key
    ) and (
      public.winner_team_match_key(g.away_team)=v_away_key or
      public.winner_team_match_key(g.sportstats_api_away_name)=v_away_key or
      public.winner_team_match_key(g.api_away_team_name)=v_away_key
    )
    and abs(extract(epoch from (g.match_time-v_kickoff)))<=10800
    and g.status='upcoming' and g.match_time>now()+interval '5 minutes'
    and coalesce(g.result_confirmed,false)=false;
    get diagnostics v_rows=row_count;
    if v_rows>0 then v_matched:=v_matched+1; v_updated:=v_updated+v_rows;
    else
      v_unmatched:=v_unmatched+1;
      if v_kickoff between now()-interval '1 day' and now()+interval '8 days'
        and jsonb_array_length(v_unmatched_samples)<50 then
        v_unmatched_samples:=v_unmatched_samples||jsonb_build_array(jsonb_build_object(
          'home_team',v_home,'away_team',v_away,'kickoff',v_kickoff,
          'home_odds',v_home_odds,'draw_odds',v_draw_odds,'away_odds',v_away_odds,
          'home_key',v_home_key,'away_key',v_away_key
        ));
      end if;
    end if;
  end loop;
  insert into public.winner_odds_import_runs(received,processed,matched,updated,unmatched,unmatched_samples)
  values(v_received,v_valid,v_matched,v_updated,v_unmatched,v_unmatched_samples);
  return jsonb_build_object('received',v_received,'processed',v_valid,'matched',v_matched,'updated',v_updated,'unmatched',v_unmatched);
end; $$;
revoke all on function public.import_winner_odds(jsonb) from public,anon;
grant execute on function public.import_winner_odds(jsonb) to authenticated;
notify pgrst,'reload schema';
