-- Mixed 1X2 + Winner-market combo tickets.
-- Already applied to Supabase project ahotbinmjzdhipgfvdvm; this file preserves the deployed schema changes.
begin;

alter table public.bet_items alter column bet_selection drop not null;
alter table public.bet_items add column if not exists market_id bigint references public.winner_markets(id) on delete set null;
alter table public.bet_items add column if not exists market_key text;
alter table public.bet_items add column if not exists market_selection text;
alter table public.bet_items add column if not exists market_label text;
alter table public.bet_items add column if not exists market_outcome_label text;
alter table public.bet_items add column if not exists market_line numeric(8,2);
create index if not exists bet_items_market_idx on public.bet_items(market_id) where market_id is not null;

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

CREATE OR REPLACE FUNCTION public.import_winner_markets(p_markets jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  item jsonb;
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
  v_received integer := 0;
  v_matched integer := 0;
  v_processed integer := 0;
  v_saved integer := 0;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  if jsonb_typeof(p_markets) <> 'array' then raise exception 'markets must be an array'; end if;
  v_received := jsonb_array_length(p_markets);

  for item in select value from jsonb_array_elements(p_markets) loop
    v_market_key := case
      when item->>'mop'='30002' and coalesce(item->>'mp','') ilike '%הימור יתרון%' then 'handicap_ft'
      when item->>'mop'='50002' and coalesce(item->>'mp','') ilike '%מעל/מתחת שערים%' then 'total_goals_2_5'
      when item->>'mop'='400002' then 'btts'
      else null end;
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
    v_market_label:=case v_market_key when 'handicap_ft' then 'הפרשי שערים'
      when 'total_goals_2_5' then 'מעל / מתחת 2.5 שערים' else 'שתי הקבוצות יבקיעו' end;
    v_home_desc:=null;
    if v_market_key='handicap_ft' then
      select o->>'desc' into v_home_desc
      from jsonb_array_elements(coalesce(item->'outcomes','[]'::jsonb)) o
      where lower(coalesce(o->>'desc','')) like '%'||lower(v_home)||'%' limit 1;
      if v_home_desc is null then continue; end if;
      v_line:=nullif(substring(replace(v_home_desc,'−','-') from '([+-]?[0-9]+([.][0-9]+)?)'),'')::numeric;
      if v_line is null then continue; end if;
    else v_line:=case when v_market_key='total_goals_2_5' then 2.5 else null end; end if;

    select jsonb_agg(jsonb_build_object('selection',mapped.selection,'label',mapped.label,'price',mapped.price) order by mapped.ordinality)
    into v_outcomes
    from (
      select x.ordinality,x.value->>'desc' as label,(x.value->>'price')::numeric as price,
        case
          when v_market_key='handicap_ft' and lower(coalesce(x.value->>'desc','')) like '%'||lower(v_home)||'%' then 'home'
          when v_market_key='handicap_ft' and lower(coalesce(x.value->>'desc','')) like '%'||lower(v_away)||'%' then 'away'
          when v_market_key='handicap_ft' and (upper(coalesce(x.value->>'desc','')) like '%X%' or coalesce(x.value->>'desc','') like '%תיקו%') then 'draw'
          when v_market_key='total_goals_2_5' and coalesce(x.value->>'desc','') like '%מעל%' then 'over'
          when v_market_key='total_goals_2_5' and coalesce(x.value->>'desc','') like '%מתחת%' then 'under'
          when v_market_key='btts' and coalesce(x.value->>'desc','') like '%כן%' then 'yes'
          when v_market_key='btts' and coalesce(x.value->>'desc','') like '%לא%' then 'no'
          else null end as selection
      from jsonb_array_elements(coalesce(item->'outcomes','[]'::jsonb)) with ordinality x(value,ordinality)
      where coalesce(x.value->>'price','') ~ '^[0-9]+([.][0-9]+)?$'
    ) mapped where mapped.selection is not null and mapped.price between 1.01 and 999.99;
    if v_outcomes is null or jsonb_array_length(v_outcomes)<2 then continue; end if;
    v_processed:=v_processed+1;
    insert into public.winner_markets(game_id,source_market_id,source_event_id,market_key,market_label,line,outcomes,active,updated_at)
    values(v_game_id,v_source_id,nullif(item->>'eId',''),v_market_key,v_market_label,v_line,v_outcomes,true,now())
    on conflict(game_id,source_market_id) do update set source_event_id=excluded.source_event_id,
      market_key=excluded.market_key,market_label=excluded.market_label,line=excluded.line,
      outcomes=excluded.outcomes,active=true,updated_at=now();
    v_saved:=v_saved+1;
  end loop;
  return jsonb_build_object('received',v_received,'matched',v_matched,'processed',v_processed,'saved',v_saved);
end; $function$

revoke all on function public.import_winner_markets(jsonb) from public,anon;
grant execute on function public.import_winner_markets(jsonb) to authenticated;

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
        v_winning_selection:=case when new.home_score+new.away_score>2 then 'over' else 'under' end;
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

-- These result synchronizers now ignore market legs; the dedicated market trigger settles them.
CREATE OR REPLACE FUNCTION public.sync_game_result(p_fixture_id integer, p_home_team text, p_away_team text, p_home_flag text, p_away_flag text, p_match_time timestamp with time zone, p_home_odds numeric, p_draw_odds numeric, p_away_odds numeric, p_home_score integer, p_away_score integer, p_status text, p_round_name text DEFAULT NULL::text, p_lock_odds boolean DEFAULT false, p_confirm_result boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$declare
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
  if p_status not in ('upcoming', 'live', 'finished', 'cancelled') then
    raise exception 'invalid status';
  end if;
  if p_home_team is null or p_away_team is null or p_match_time is null then
    raise exception 'incomplete fixture';
  end if;

  if p_home_odds is not null and (p_home_odds < 1.01 or p_home_odds > 99.99) then
    p_home_odds := null;
  end if;
  if p_draw_odds is not null and (p_draw_odds < 1.01 or p_draw_odds > 99.99) then
    p_draw_odds := null;
  end if;
  if p_away_odds is not null and (p_away_odds < 1.01 or p_away_odds > 99.99) then
    p_away_odds := null;
  end if;

  insert into public.games (
    fixture_id, home_team, away_team, home_flag, away_flag, match_time,
    home_odds, draw_odds, away_odds, home_score, away_score, status,
    round_name, odds_locked, result_confirmed
  ) values (
    p_fixture_id, p_home_team, p_away_team, p_home_flag, p_away_flag, p_match_time,
    p_home_odds, p_draw_odds, p_away_odds,
    case
      when coalesce(p_confirm_result, false) and p_status in ('finished', 'cancelled') then coalesce(p_home_score, 0)
      else 0
    end,
    case
      when coalesce(p_confirm_result, false) and p_status in ('finished', 'cancelled') then coalesce(p_away_score, 0)
      else 0
    end,
    case
      when coalesce(p_confirm_result, false) and p_status in ('finished', 'cancelled') then p_status
      else 'upcoming'
    end,
    p_round_name,
    coalesce(p_lock_odds, false)
      and p_home_odds is not null and p_draw_odds is not null and p_away_odds is not null,
    coalesce(p_confirm_result, false) and p_status in ('finished', 'cancelled')
  )
  on conflict (fixture_id) do update set
    home_team = excluded.home_team,
    away_team = excluded.away_team,
    home_flag = excluded.home_flag,
    away_flag = excluded.away_flag,
    match_time = excluded.match_time,
    round_name = coalesce(excluded.round_name, games.round_name),
    home_odds = case
when games.odds_locked then games.home_odds      when excluded.odds_locked then excluded.home_odds
      else coalesce(excluded.home_odds, games.home_odds)
    end,
    draw_odds = case
when games.odds_locked then games.draw_odds      when excluded.odds_locked then excluded.draw_odds
      else coalesce(excluded.draw_odds, games.draw_odds)
    end,
    away_odds = case
      when games.odds_locked then games.away_odds      else coalesce(excluded.away_odds, games.away_odds)
    end,
    odds_locked = games.odds_locked or excluded.odds_locked,
    home_score = case
      when games.result_confirmed or games.status in ('finished', 'cancelled') then games.home_score
      when excluded.status in ('finished', 'cancelled') then excluded.home_score
      else games.home_score
    end,
    away_score = case
      when games.result_confirmed or games.status in ('finished', 'cancelled') then games.away_score
      when excluded.status in ('finished', 'cancelled') then excluded.away_score
      else games.away_score
    end,
    status = case
      when games.result_confirmed or games.status in ('finished', 'cancelled') then games.status
      when excluded.status in ('finished', 'cancelled') then excluded.status
      else games.status
    end,
    result_confirmed = games.result_confirmed or excluded.result_confirmed
  returning * into v_game;

  if v_game.status in ('finished', 'cancelled') then
    for v_bet in
      select * from public.bets
      where game_id = v_game.id
        and status = 'pending'
        and not exists (select 1 from public.bet_items i where i.bet_id = bets.id)
      order by id
      for update
    loop
      if v_game.status = 'cancelled' then
        update public.bets set status = 'void' where id = v_bet.id;
        update public.profiles
        set balance = balance + v_bet.bet_amount
        where id = v_bet.user_id;
      else
        v_won := (v_bet.bet_selection = '1' and v_game.home_score > v_game.away_score)
          or (v_bet.bet_selection = 'X' and v_game.home_score = v_game.away_score)
          or (v_bet.bet_selection = '2' and v_game.home_score < v_game.away_score);
        if v_won then
          update public.bets set status = 'won' where id = v_bet.id;
          update public.profiles
          set balance = balance + v_bet.potential_payout
          where id = v_bet.user_id;
        else
          update public.bets set status = 'lost' where id = v_bet.id;
        end if;
      end if;
      v_settled := v_settled + 1;
    end loop;

    for v_item in
      select i.*
      from public.bet_items i
      join public.bets b on b.id = i.bet_id
      where i.game_id = v_game.id
        and i.status = 'pending'
        and b.status = 'pending'
        and i.market_id is null
      order by i.id
      for update of i
    loop
      if v_game.status = 'cancelled' then
        update public.bet_items set status = 'void' where id = v_item.id;
      else
        v_won := (v_item.bet_selection = '1' and v_game.home_score > v_game.away_score)
          or (v_item.bet_selection = 'X' and v_game.home_score = v_game.away_score)
          or (v_item.bet_selection = '2' and v_game.home_score < v_game.away_score);
        update public.bet_items
        set status = case when v_won then 'won' else 'lost' end
        where id = v_item.id;
      end if;

      select * into v_slip from public.bets where id = v_item.bet_id for update;
      if v_slip.status <> 'pending' then
        continue;
      end if;

      if exists (select 1 from public.bet_items where bet_id = v_slip.id and status = 'lost') then
        update public.bets set status = 'lost' where id = v_slip.id;
      elsif exists (select 1 from public.bet_items where bet_id = v_slip.id and status = 'pending') then
        v_product := 1;
        for v_leg in
          select odds, status from public.bet_items where bet_id = v_slip.id
        loop
          v_product := v_product * (case when v_leg.status = 'void' then 1 else v_leg.odds end);
        end loop;
        update public.bets
        set odds = round(v_product, 4),
            potential_payout = round(v_slip.bet_amount * v_product, 2)
        where id = v_slip.id;
      else
        select count(*), count(*) filter (where status = 'void')
          into v_legs, v_voids
        from public.bet_items
        where bet_id = v_slip.id;
        v_product := 1;
        for v_leg in
          select odds, status from public.bet_items where bet_id = v_slip.id
        loop
          v_product := v_product * (case when v_leg.status = 'void' then 1 else v_leg.odds end);
        end loop;
        v_payout := round(v_slip.bet_amount * v_product, 2);
        if v_voids = v_legs then
          update public.bets
          set status = 'void', odds = 1, potential_payout = v_slip.bet_amount
          where id = v_slip.id;
          update public.profiles
          set balance = balance + v_slip.bet_amount
          where id = v_slip.user_id;
        else
          update public.bets
          set status = 'won', odds = round(v_product, 4), potential_payout = v_payout
          where id = v_slip.id;
          update public.profiles
          set balance = balance + v_payout
          where id = v_slip.user_id;
        end if;
      end if;
      v_settled := v_settled + 1;
    end loop;
  end if;

  return jsonb_build_object(
    'fixture_id', p_fixture_id,
    'status', v_game.status,
    'home_score', v_game.home_score,
    'away_score', v_game.away_score,
    'settled', v_settled
  );
end;$function$

CREATE OR REPLACE FUNCTION public.sync_sportstats_result(p_match_code text, p_home_score integer, p_away_score integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    where i.game_id = v_game.id and i.status = 'pending' and b.status = 'pending' and i.market_id is null
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
$function$

CREATE OR REPLACE FUNCTION public.sync_api_football_result(p_api_fixture_id bigint, p_status text, p_home_score integer, p_away_score integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  for v_item in
    select i.* from public.bet_items i
    join public.bets b on b.id=i.bet_id
    where i.game_id=v_game.id and i.status='pending' and b.status='pending' and i.market_id is null
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
$function$


revoke all on function public.settle_winner_market_bets() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
