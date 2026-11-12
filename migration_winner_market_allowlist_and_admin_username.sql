-- Keep Winner ingestion limited to the three non-1X2 markets requested.
-- Full-time 1X2 remains in games.home_odds/draw_odds/away_odds.
begin;

-- Hide old imported markets outside the supported shortlist. Historical bets are retained.
update public.winner_markets
set active=false, updated_at=now()
where market_key not in ('handicap_ft','total_goals_2_5','btts');

delete from public.market_display_settings
where market_key not in ('handicap_ft','total_goals_2_5','btts');

-- Do not accept unsupported Winner market types even if an old extension sends them.
create or replace function public.import_winner_markets(p_markets jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public
as $function$
declare
  item jsonb;
  x record;
  v_desc text;
  v_home text;
  v_away text;
  v_date date;
  v_hhmm text;
  v_kickoff timestamptz;
  v_game_id bigint;
  v_market_key text;
  v_market_label text;
  v_source_id text;
  v_home_desc text;
  v_line numeric;
  v_outcomes jsonb;
  v_received integer:=0;
  v_matched integer:=0;
  v_processed integer:=0;
  v_saved integer:=0;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  if jsonb_typeof(p_markets)<>'array' then raise exception 'markets must be an array'; end if;
  v_received:=jsonb_array_length(p_markets);

  for item in select value from jsonb_array_elements(p_markets) loop
    -- Only full-time handicap, total goals over/under and BTTS are accepted.
    -- Full-time 1X2 is stored separately in games odds columns.
    if coalesce(item->>'mop','') !~ '^[0-9]+$'
       or item->>'mop' not in ('30002','50002','400002') then
      continue;
    end if;

    v_market_key:=case
      when item->>'mop'='30002' and coalesce(item->>'mp','') ilike '%הימור יתרון%'
        and coalesce(item->>'mp','') not ilike '%מחצית ראשונה%' then 'handicap_ft'
      when item->>'mop'='50002' and coalesce(item->>'mp','') ilike '%מעל/מתחת שערים%'
        and coalesce(item->>'mp','') not ilike '%מחצית ראשונה%' then 'total_goals_2_5'
      when item->>'mop'='400002' then 'btts'
      else null
    end;
    if v_market_key is null then continue; end if;

    v_desc:=nullif(trim(item->>'desc'),'');
    v_source_id:=nullif(item->>'mId','');
    v_hhmm:=lpad(coalesce(item->>'m_hour',''),4,'0');
    if v_desc is null or v_source_id is null or length(coalesce(item->>'e_date',''))<>6
       or v_hhmm !~ '^[0-2][0-9][0-5][0-9]$' then continue; end if;
    v_home:=nullif(trim(split_part(v_desc,' - ',1)),'');
    v_away:=nullif(trim(split_part(v_desc,' - ',2)),'');
    if v_home is null or v_away is null then continue; end if;

    begin
      v_date:=to_date(item->>'e_date','YYMMDD');
      v_kickoff:=(v_date+make_time(substr(v_hhmm,1,2)::integer,substr(v_hhmm,3,2)::integer,0)) at time zone 'Asia/Jerusalem';
    exception when others then continue; end;

    select g.id into v_game_id from public.games g
    where (lower(trim(g.home_team))=lower(v_home) or lower(trim(coalesce(g.sportstats_api_home_name,'')))=lower(v_home))
      and (lower(trim(g.away_team))=lower(v_away) or lower(trim(coalesce(g.sportstats_api_away_name,'')))=lower(v_away))
      and abs(extract(epoch from (g.match_time-v_kickoff)))<=1800 and g.status='upcoming'
    order by abs(extract(epoch from (g.match_time-v_kickoff))) limit 1;
    if v_game_id is null then continue; end if;
    v_matched:=v_matched+1;
    v_market_label:=case v_market_key
      when 'handicap_ft' then 'הפרש שערים'
      when 'total_goals_2_5' then 'מעל/מתחת שערים'
      else 'שתי הקבוצות יבקיעו'
    end;
    v_home_desc:=null;
    v_line:=null;

    if v_market_key='handicap_ft' then
      select o->>'desc' into v_home_desc from jsonb_array_elements(coalesce(item->'outcomes','[]'::jsonb)) o
      where lower(coalesce(o->>'desc','')) like '%'||lower(v_home)||'%' limit 1;
      if v_home_desc is null then continue; end if;
      v_line:=nullif(substring(replace(v_home_desc,'−','-') from '([+-]?[0-9]+([.][0-9]+)?)'),'')::numeric;
      if v_line is null then continue; end if;
    elsif v_market_key='total_goals_2_5' then
      select nullif(substring(replace(o->>'desc','−','-') from '([0-9]+([.][0-9]+)?)'),'')::numeric into v_line
      from jsonb_array_elements(coalesce(item->'outcomes','[]'::jsonb)) o
      where coalesce(o->>'desc','') ilike '%מעל%' or coalesce(o->>'desc','') ilike '%מתחת%' limit 1;
      if v_line is null then continue; end if;
    end if;

    select jsonb_agg(jsonb_build_object(
      'selection',mapped.selection,'label',mapped.label,'price',mapped.price
    ) order by mapped.ordinality)
    into v_outcomes
    from (
      select o.ordinality,o.value->>'desc' as label,(o.value->>'price')::numeric as price,
        case
          when v_market_key='handicap_ft' and lower(coalesce(o.value->>'desc','')) like '%'||lower(v_home)||'%' then 'home'
          when v_market_key='handicap_ft' and lower(coalesce(o.value->>'desc','')) like '%'||lower(v_away)||'%' then 'away'
          when v_market_key='handicap_ft' and (upper(coalesce(o.value->>'desc','')) like '%X%' or coalesce(o.value->>'desc','') like '%תיקו%') then 'draw'
          when v_market_key='total_goals_2_5' and coalesce(o.value->>'desc','') like '%מעל%' then 'over'
          when v_market_key='total_goals_2_5' and coalesce(o.value->>'desc','') like '%מתחת%' then 'under'
          when v_market_key='btts' and coalesce(o.value->>'desc','') like '%כן%' then 'yes'
          when v_market_key='btts' and coalesce(o.value->>'desc','') like '%לא%' then 'no'
          else null
        end as selection
      from jsonb_array_elements(coalesce(item->'outcomes','[]'::jsonb)) with ordinality o(value,ordinality)
      where coalesce(o.value->>'price','') ~ '^[0-9]+([.][0-9]+)?$'
    ) mapped
    where mapped.selection is not null and mapped.price between 1.01 and 999.99;

    if v_outcomes is null or jsonb_array_length(v_outcomes)<2 then continue; end if;
    v_processed:=v_processed+1;
    insert into public.market_display_settings(market_key,label,enabled)
    values(v_market_key,v_market_label,true)
    on conflict(market_key) do update set label=excluded.label;
    insert into public.winner_markets(game_id,source_market_id,source_event_id,market_key,market_label,line,outcomes,active,updated_at)
    values(v_game_id,v_source_id,nullif(item->>'eId',''),v_market_key,v_market_label,v_line,v_outcomes,true,now())
    on conflict(game_id,source_market_id) do update set
      source_event_id=excluded.source_event_id,market_key=excluded.market_key,
      market_label=excluded.market_label,line=excluded.line,outcomes=excluded.outcomes,
      active=true,updated_at=now();
    v_saved:=v_saved+1;
  end loop;
  return jsonb_build_object('received',v_received,'matched',v_matched,'processed',v_processed,'saved',v_saved);
end;
$function$;

revoke all on function public.import_winner_markets(jsonb) from public,anon;
grant execute on function public.import_winner_markets(jsonb) to authenticated;

create or replace function public.admin_update_username(p_user_id uuid,p_username text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_username text:=trim(coalesce(p_username,''));
  v_old_username text;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  if v_username !~ '^[[:alnum:]_א-ת.-]{2,24}$' then
    raise exception 'שם המשתמש חייב להכיל 2–24 תווים: אותיות, מספרים, נקודה, מקף או קו תחתון';
  end if;
  if exists(select 1 from public.profiles where id<>p_user_id and lower(username)=lower(v_username)) then
    raise exception 'שם המשתמש כבר תפוס';
  end if;
  update public.profiles set username=v_username
  where id=p_user_id and is_deleted=false
  returning username into v_username;
  if not found then raise exception 'המשתמש לא נמצא או נמחק'; end if;
  insert into public.admin_audit_log(admin_id,action,target_user_id,details)
  values(auth.uid(),'update_username',p_user_id,jsonb_build_object('new_username',v_username));
  return jsonb_build_object('user_id',p_user_id,'username',v_username);
end;
$function$;

revoke all on function public.admin_update_username(uuid,text) from public,anon;
grant execute on function public.admin_update_username(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
