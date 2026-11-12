-- Expand the DMW Winner catalogue to every football market and allow admin settlement for stat-based markets.
-- Run after migration_dynamic_winner_markets.sql and migration_market_parlay_support.sql.
begin;

alter table public.winner_markets drop constraint if exists winner_markets_market_key_check;
alter table public.market_display_settings drop constraint if exists market_display_settings_market_key_check;
alter table public.winner_markets add column if not exists settled_selection text;
alter table public.winner_markets add column if not exists settled_at timestamptz;
alter table public.winner_markets add column if not exists settled_by uuid references auth.users(id) on delete set null;
create index if not exists winner_markets_unsettled_idx on public.winner_markets(game_id,market_key) where settled_at is null and active=true;

CREATE OR REPLACE FUNCTION public.import_winner_markets(p_markets jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    if coalesce(item->>'mop','') !~ '^[0-9]+$' then continue; end if;
    -- Full-time 1X2 is already stored in games.home/draw/away_odds.
    if item->>'mop'='10002' then continue; end if;
    v_market_key:=case
      when item->>'mop'='30002' and coalesce(item->>'mp','') ilike '%הימור יתרון%'
        and coalesce(item->>'mp','') not ilike '%מחצית ראשונה%' then 'handicap_ft'
      when item->>'mop'='50002' and coalesce(item->>'mp','') ilike '%מעל/מתחת שערים%'
        and coalesce(item->>'mp','') not ilike '%מחצית ראשונה%' then 'total_goals_2_5'
      when item->>'mop'='400002' then 'btts'
      else 'winner_'||(item->>'mop')||case when coalesce(item->>'mp','') ilike '%מחצית ראשונה%' then '_first_half' else '' end
    end;

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
    v_market_label:=coalesce(nullif(trim(item->>'mp'),''),'שוק Winner '||(item->>'mop'));
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
          else nullif(trim(o.value->>'desc'),'')
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
end; $function$

revoke all on function public.import_winner_markets(jsonb) from public,anon;
grant execute on function public.import_winner_markets(jsonb) to authenticated;

CREATE OR REPLACE FUNCTION public.admin_get_market_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('key',market_key,'label',label,'enabled',enabled)
    order by case market_key when 'handicap_ft' then 1 when 'total_goals_2_5' then 2 when 'btts' then 3 else 10 end,label),'[]'::jsonb)
  into v from public.market_display_settings;
  return v;
end; $function$

revoke all on function public.admin_get_market_settings() from public,anon;
grant execute on function public.admin_get_market_settings() to authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_market_setting(p_market_key text, p_enabled boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_label text;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  update public.market_display_settings set enabled=coalesce(p_enabled,false),updated_at=now()
  where market_key=p_market_key returning label into v_label;
  if not found then raise exception 'סוג ההימור לא נמצא'; end if;
  return jsonb_build_object('key',p_market_key,'label',v_label,'enabled',p_enabled);
end; $function$

revoke all on function public.admin_set_market_setting(text,boolean) from public,anon;
grant execute on function public.admin_set_market_setting(text,boolean) to authenticated;

CREATE OR REPLACE FUNCTION public.admin_settle_winner_market(p_market_id bigint, p_winning_selection text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_market public.winner_markets%rowtype;
  v_game public.games%rowtype;
  v_bet record;
  v_item record;
  v_slip public.bets%rowtype;
  v_product numeric;
  v_payout numeric(14,2);
  v_total integer;
  v_voids integer;
  v_singles integer:=0;
  v_legs integer:=0;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  select * into v_market from public.winner_markets where id=p_market_id and active=true for update;
  if not found then raise exception 'השוק לא נמצא'; end if;
  if v_market.settled_at is not null then raise exception 'השוק כבר נסגר'; end if;
  if not exists(select 1 from jsonb_array_elements(v_market.outcomes) o where o->>'selection'=p_winning_selection) then
    raise exception 'תוצאה זוכה לא תקינה';
  end if;
  select * into v_game from public.games where id=v_market.game_id for update;
  if not found or v_game.status not in ('finished','cancelled') or not coalesce(v_game.result_confirmed,false) then
    raise exception 'אפשר לסגור שוק רק אחרי אישור תוצאת המשחק';
  end if;
  update public.winner_markets set settled_selection=p_winning_selection,settled_at=now(),settled_by=auth.uid()
  where id=p_market_id;

  for v_bet in select * from public.bets where market_id=p_market_id and status='pending' for update loop
    if v_market.market_key in ('handicap_ft','total_goals_2_5','btts') then continue; end if;
    if v_bet.market_selection=p_winning_selection then
      update public.bets set status='won' where id=v_bet.id;
      update public.profiles set balance=balance+v_bet.potential_payout where id=v_bet.user_id;
    else update public.bets set status='lost' where id=v_bet.id; end if;
    v_singles:=v_singles+1;
  end loop;

  for v_item in
    select i.* from public.bet_items i join public.bets b on b.id=i.bet_id
    where i.market_id=p_market_id and i.status='pending' and b.status='pending'
      and v_market.market_key not in ('handicap_ft','total_goals_2_5','btts')
    order by i.id for update of i
  loop
    update public.bet_items set status=case when market_selection=p_winning_selection then 'won' else 'lost' end
    where id=v_item.id;
    select * into v_slip from public.bets where id=v_item.bet_id for update;
    if v_slip.status<>'pending' then continue; end if;
    if exists(select 1 from public.bet_items where bet_id=v_slip.id and status='lost') then
      update public.bets set status='lost' where id=v_slip.id;
    elsif exists(select 1 from public.bet_items where bet_id=v_slip.id and status='pending') then
      v_product:=1;
      for v_item in select odds,status from public.bet_items where bet_id=v_slip.id loop
        v_product:=v_product*(case when v_item.status='void' then 1 else v_item.odds end);
      end loop;
      update public.bets set odds=round(v_product,4),potential_payout=round(v_slip.bet_amount*v_product,2) where id=v_slip.id;
    else
      select count(*),count(*) filter(where status='void') into v_total,v_voids from public.bet_items where bet_id=v_slip.id;
      v_product:=1;
      for v_item in select odds,status from public.bet_items where bet_id=v_slip.id loop
        v_product:=v_product*(case when v_item.status='void' then 1 else v_item.odds end);
      end loop;
      v_payout:=round(v_slip.bet_amount*v_product,2);
      if v_voids=v_total then
        update public.bets set status='void',odds=1,potential_payout=v_slip.bet_amount where id=v_slip.id;
        update public.profiles set balance=balance+v_slip.bet_amount where id=v_slip.user_id;
      else
        update public.bets set status='won',odds=round(v_product,4),potential_payout=v_payout where id=v_slip.id;
        update public.profiles set balance=balance+v_payout where id=v_slip.user_id;
      end if;
    end if;
    v_legs:=v_legs+1;
  end loop;
  return jsonb_build_object('market_id',p_market_id,'winning_selection',p_winning_selection,
    'settled_single_bets',v_singles,'settled_parlay_legs',v_legs);
end; $function$

revoke all on function public.admin_settle_winner_market(bigint,text) from public,anon;
grant execute on function public.admin_settle_winner_market(bigint,text) to authenticated;

CREATE OR REPLACE FUNCTION public.place_parlay(p_legs jsonb, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_amount numeric(12,2);
  v_balance numeric(14,2);
  v_bet_id bigint;
  v_count integer;
  v_distinct integer;
  v_product numeric := 1;
  v_payout numeric(14,2);
  v_leg jsonb;
  v_game public.games%rowtype;
  v_market public.winner_markets%rowtype;
  v_selection text;
  v_market_selection text;
  v_market_id bigint;
  v_market_label text;
  v_outcome_label text;
  v_line numeric(8,2);
  v_price numeric(8,2);
  v_resolved jsonb := '[]'::jsonb;
  v_first_game_id bigint;
  v_first_selection text;
  v_first_market_id bigint;
  v_first_market_key text;
  v_first_market_selection text;
  v_first_market_label text;
  v_first_outcome_label text;
  v_first_market_line numeric(8,2);
  v_calc record;
begin
  if v_uid is null then raise exception 'יש להתחבר'; end if;
  if p_legs is null or jsonb_typeof(p_legs) <> 'array' then raise exception 'בחרו לפחות משחק אחד'; end if;
  v_count := jsonb_array_length(p_legs);
  if v_count < 1 or v_count > 8 then raise exception 'אפשר בין משחק אחד ל־8 משחקים'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'סכום לא תקין'; end if;
  v_amount := round(p_amount,2);
  if v_amount <= 0 then raise exception 'סכום לא תקין'; end if;

  if exists (
    select 1 from jsonb_array_elements(p_legs) x
    where coalesce(x->>'game_id','') !~ '^[0-9]+$'
       or ((x ? 'market_id' and coalesce(x->>'market_id','') !~ '^[0-9]+$')
         or (not (x ? 'market_id') and coalesce(x->>'selection','') not in ('1','X','2')))
  ) then raise exception 'בחירה לא תקינה'; end if;

  select count(distinct (x->>'game_id')::bigint) into v_distinct
  from jsonb_array_elements(p_legs) x;
  if v_distinct <> v_count then raise exception 'אי אפשר לבחור אותו משחק פעמיים'; end if;

  for v_leg in select value from jsonb_array_elements(p_legs) order by (value->>'game_id')::bigint loop
    select * into v_game from public.games where id=(v_leg->>'game_id')::bigint for update;
    if not found then raise exception 'המשחק לא נמצא'; end if;
    if v_game.status <> 'upcoming' or v_game.match_time is null
       or v_game.match_time <= now()+interval '5 minutes' then
      raise exception 'ההימור נעול — נותרו פחות מ־5 דקות לתחילת המשחק';
    end if;

    v_market_id := null; v_market_selection := null; v_market_label := null;
    v_outcome_label := null; v_line := null; v_selection := null;

    if v_leg ? 'market_id' then
      v_market_id := (v_leg->>'market_id')::bigint;
      v_market_selection := nullif(v_leg->>'market_selection','');
      if v_market_selection is null then raise exception 'בחירת שוק לא תקינה'; end if;
      select * into v_market from public.winner_markets
      where id=v_market_id and game_id=v_game.id and active=true for update;
      if not found then raise exception 'השוק כבר אינו זמין'; end if;
      if v_market.settled_at is not null then raise exception 'השוק כבר נסגר'; end if;
      if not exists(select 1 from public.market_display_settings where market_key=v_market.market_key and enabled=true) then
        raise exception 'סוג ההימור אינו פעיל כרגע';
      end if;
      select (o->>'price')::numeric,o->>'label' into v_price,v_outcome_label
      from jsonb_array_elements(v_market.outcomes) o
      where o->>'selection'=v_market_selection limit 1;
      if v_price is null or v_price<1.01 then raise exception 'היחס לשוק אינו זמין'; end if;
      v_market_label:=v_market.market_label; v_line:=v_market.line;
    else
      v_selection:=v_leg->>'selection';
      v_price:=case v_selection when '1' then v_game.home_odds when 'X' then v_game.draw_odds else v_game.away_odds end;
      if v_price is null or v_price<1.01 then raise exception 'היחס לא זמין'; end if;
    end if;

    if v_resolved='[]'::jsonb then
      v_first_game_id:=v_game.id; v_first_selection:=v_selection;
      v_first_market_id:=v_market_id;
      v_first_market_key:=case when v_market_id is null then null else v_market.market_key end;
      v_first_market_selection:=v_market_selection; v_first_market_label:=v_market_label;
      v_first_outcome_label:=v_outcome_label; v_first_market_line:=v_line;
    end if;
    v_product:=v_product*v_price;
    v_resolved:=v_resolved||jsonb_build_array(jsonb_build_object(
      'game_id',v_game.id,'bet_selection',v_selection,'market_id',v_market_id,
      'market_key',case when v_market_id is null then null else v_market.market_key end,
      'market_selection',v_market_selection,'market_label',v_market_label,
      'market_outcome_label',v_outcome_label,'market_line',v_line,'odds',v_price));
  end loop;

  if v_amount*v_product>99999999.99 then raise exception 'הסכום חורג מהתקרה'; end if;
  v_payout:=round(v_amount*v_product,2);
  select balance into v_balance from public.profiles where id=v_uid for update;
  if not found then raise exception 'הפרופיל לא נמצא'; end if;
  if v_balance<v_amount then raise exception 'יתרה לא מספיקה'; end if;
  update public.profiles set balance=balance-v_amount where id=v_uid;

  insert into public.bets(user_id,game_id,bet_selection,bet_amount,odds,potential_payout,status,
    market_id,market_key,market_label,market_selection,market_outcome_label,market_line)
  values(v_uid,case when v_count=1 then v_first_game_id else null end,
    case when v_count=1 then v_first_selection else null end,v_amount,round(v_product,4),v_payout,'pending',
    case when v_count=1 then v_first_market_id else null end,
    case when v_count=1 then v_first_market_key else null end,
    case when v_count=1 then v_first_market_label else null end,
    case when v_count=1 then v_first_market_selection else null end,
    case when v_count=1 then v_first_outcome_label else null end,
    case when v_count=1 then v_first_market_line else null end)
  returning id into v_bet_id;

  insert into public.bet_items(bet_id,game_id,bet_selection,odds,market_id,market_key,market_selection,market_label,market_outcome_label,market_line)
  select v_bet_id,(x->>'game_id')::bigint,nullif(x->>'bet_selection',''),(x->>'odds')::numeric,
    nullif(x->>'market_id','')::bigint,nullif(x->>'market_key',''),nullif(x->>'market_selection',''),
    nullif(x->>'market_label',''),nullif(x->>'market_outcome_label',''),nullif(x->>'market_line','')::numeric
  from jsonb_array_elements(v_resolved) x;

  select balance into v_balance from public.profiles where id=v_uid;
  return jsonb_build_object('bet_id',v_bet_id,'legs',v_count,'odds',round(v_product,4),
    'total_odds',round(v_product,4),'stake',v_amount,'potential_payout',v_payout,'status','pending','balance',v_balance);
end; $function$

revoke all on function public.place_parlay(jsonb,numeric) from public,anon;
grant execute on function public.place_parlay(jsonb,numeric) to authenticated;

CREATE OR REPLACE FUNCTION public.place_market_bet(p_market_id bigint, p_selection text, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_market public.winner_markets%rowtype;
  v_game public.games%rowtype;
  v_price numeric(14,4);
  v_label text;
  v_amount numeric(10,2);
  v_payout numeric(14,2);
  v_balance numeric(14,2);
  v_bet_id bigint;
begin
  if v_uid is null then raise exception 'יש להתחבר'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'סכום לא תקין'; end if;
  v_amount := round(p_amount,2);
  select * into v_market from public.winner_markets where id=p_market_id and active=true for update;
  if not found then raise exception 'השוק כבר אינו זמין'; end if;
  if v_market.settled_at is not null then raise exception 'השוק כבר נסגר'; end if;
  if not exists(select 1 from public.market_display_settings where market_key=v_market.market_key and enabled=true) then
    raise exception 'סוג ההימור אינו פעיל כרגע';
  end if;
  select * into v_game from public.games where id=v_market.game_id for update;
  if not found or v_game.status<>'upcoming' or v_game.match_time<=now()+interval '5 minutes' then
    raise exception 'ההימור נעול — המשחק עומד להתחיל או כבר התחיל';
  end if;
  select (o->>'price')::numeric, o->>'label'
    into v_price,v_label
    from jsonb_array_elements(v_market.outcomes) o
   where o->>'selection'=p_selection
   limit 1;
  if v_price is null or v_price<1.01 then raise exception 'היחס אינו זמין'; end if;
  if v_amount*v_price>99999999.99 then raise exception 'הסכום חורג מהתקרה'; end if;
  v_payout := round(v_amount*v_price,2);
  select balance into v_balance from public.profiles where id=v_uid for update;
  if not found then raise exception 'הפרופיל לא נמצא'; end if;
  if v_balance<v_amount then raise exception 'יתרה לא מספיקה'; end if;
  update public.profiles set balance=balance-v_amount where id=v_uid;
  insert into public.bets(
    user_id,game_id,bet_selection,bet_amount,odds,potential_payout,status,
    market_id,market_key,market_label,market_selection,market_outcome_label,market_line
  ) values (
    v_uid,v_game.id,null,v_amount,v_price,v_payout,'pending',
    v_market.id,v_market.market_key,v_market.market_label,p_selection,v_label,v_market.line
  ) returning id into v_bet_id;
  select balance into v_balance from public.profiles where id=v_uid;
  return jsonb_build_object('bet_id',v_bet_id,'odds',v_price,'potential_payout',v_payout,'balance',v_balance);
end; $function$

revoke all on function public.place_market_bet(bigint,text,numeric) from public,anon;
grant execute on function public.place_market_bet(bigint,text,numeric) to authenticated;

CREATE OR REPLACE FUNCTION public.settle_winner_market_parlay_legs()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item record;
  v_calc record;
  v_slip public.bets%rowtype;
  v_winning_selection text;
  v_adjusted_home numeric;
  v_product numeric;
  v_payout numeric(14,2);
  v_total integer;
  v_voids integer;
begin
  if new.status not in ('finished','cancelled') or not coalesce(new.result_confirmed,false) then return new; end if;
  for v_item in
    select i.* from public.bet_items i join public.bets b on b.id=i.bet_id
    where i.game_id=new.id and i.market_id is not null and i.status='pending' and b.status='pending'
    order by i.id for update of i
  loop
    if new.status='cancelled' then
      update public.bet_items set status='void' where id=v_item.id;
    else
      if v_item.market_key='btts' then
        v_winning_selection:=case when new.home_score>0 and new.away_score>0 then 'yes' else 'no' end;
      elsif v_item.market_key='total_goals_2_5' then
        v_winning_selection:=case when new.home_score+new.away_score>coalesce(v_item.market_line,2.5) then 'over' else 'under' end;
      elsif v_item.market_key='handicap_ft' then
        v_adjusted_home:=new.home_score+coalesce(v_item.market_line,0);
        v_winning_selection:=case when v_adjusted_home>new.away_score then 'home'
          when v_adjusted_home=new.away_score then 'draw' else 'away' end;
      else
        continue;
      end if;
      update public.bet_items set status=case when market_selection=v_winning_selection then 'won' else 'lost' end
      where id=v_item.id;
    end if;

    select * into v_slip from public.bets where id=v_item.bet_id for update;
    if v_slip.status<>'pending' then continue; end if;
    if exists(select 1 from public.bet_items where bet_id=v_slip.id and status='lost') then
      update public.bets set status='lost' where id=v_slip.id;
    elsif exists(select 1 from public.bet_items where bet_id=v_slip.id and status='pending') then
      v_product:=1;
      for v_calc in select odds,status from public.bet_items where bet_id=v_slip.id loop
        v_product:=v_product*(case when v_calc.status='void' then 1 else v_calc.odds end);
      end loop;
      update public.bets set odds=round(v_product,4),potential_payout=round(v_slip.bet_amount*v_product,2) where id=v_slip.id;
    else
      select count(*),count(*) filter(where status='void') into v_total,v_voids from public.bet_items where bet_id=v_slip.id;
      v_product:=1;
      for v_calc in select odds,status from public.bet_items where bet_id=v_slip.id loop
        v_product:=v_product*(case when v_calc.status='void' then 1 else v_calc.odds end);
      end loop;
      v_payout:=round(v_slip.bet_amount*v_product,2);
      if v_voids=v_total then
        update public.bets set status='void',odds=1,potential_payout=v_slip.bet_amount where id=v_slip.id;
        update public.profiles set balance=balance+v_slip.bet_amount where id=v_slip.user_id;
      else
        update public.bets set status='won',odds=round(v_product,4),potential_payout=v_payout where id=v_slip.id;
        update public.profiles set balance=balance+v_payout where id=v_slip.user_id;
      end if;
    end if;
  end loop;
  return new;
end; $function$

revoke all on function public.settle_winner_market_parlay_legs() from public,anon,authenticated;
drop trigger if exists settle_winner_market_parlay_legs_trigger on public.games;
create trigger settle_winner_market_parlay_legs_trigger
after update of status,home_score,away_score,result_confirmed on public.games
for each row execute function public.settle_winner_market_parlay_legs();

CREATE OR REPLACE FUNCTION public.settle_winner_market_bets()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b record;
  v_winning_selection text;
  v_adjusted_home numeric;
begin
  if new.status not in ('finished','cancelled') or not coalesce(new.result_confirmed,false) then return new; end if;
  for b in
    select id,user_id,bet_amount,potential_payout,market_key,market_selection,market_line
    from public.bets
    where game_id=new.id and market_id is not null and status='pending'
    for update
  loop
    if new.status='cancelled' then
      update public.bets set status='void' where id=b.id;
      update public.profiles set balance=balance+b.bet_amount where id=b.user_id;
      continue;
    end if;
    if b.market_key='btts' then
      v_winning_selection := case when new.home_score>0 and new.away_score>0 then 'yes' else 'no' end;
    elsif b.market_key='total_goals_2_5' then
      v_winning_selection := case when new.home_score+new.away_score>coalesce(v_market.line,2.5) then 'over' else 'under' end;
    elsif b.market_key='handicap_ft' then
      v_adjusted_home := new.home_score + coalesce(b.market_line,0);
      v_winning_selection := case when v_adjusted_home>new.away_score then 'home'
        when v_adjusted_home=new.away_score then 'draw' else 'away' end;
    else
      continue;
    end if;
    if b.market_selection=v_winning_selection then
      update public.bets set status='won' where id=b.id;
      update public.profiles set balance=balance+b.potential_payout where id=b.user_id;
    else
      update public.bets set status='lost' where id=b.id;
    end if;
  end loop;
  return new;
end; $function$

revoke all on function public.settle_winner_market_bets() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
