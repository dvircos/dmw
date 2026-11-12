-- Dynamic Winner markets for all leagues. Run once in Supabase SQL Editor.
-- Existing 1X2 bets and settlement remain unchanged.

create table if not exists public.winner_markets (
  id bigserial primary key,
  game_id bigint not null references public.games(id) on delete cascade,
  source_market_id text not null,
  source_event_id text,
  market_key text not null check (market_key in ('handicap_ft','total_goals_2_5','btts')),
  market_label text not null,
  line numeric(8,2),
  outcomes jsonb not null default '[]'::jsonb,
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  unique (game_id, source_market_id),
  check (jsonb_typeof(outcomes) = 'array')
);
create index if not exists winner_markets_game_idx on public.winner_markets(game_id, active);
alter table public.winner_markets enable row level security;
drop policy if exists winner_markets_read on public.winner_markets;
create policy winner_markets_read on public.winner_markets for select to anon, authenticated using (active = true);
grant select on public.winner_markets to anon, authenticated;

create table if not exists public.market_display_settings (
  market_key text primary key check (market_key in ('handicap_ft','total_goals_2_5','btts')),
  label text not null,
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.market_display_settings enable row level security;
revoke all on public.market_display_settings from anon, authenticated, public;
insert into public.market_display_settings(market_key,label,enabled) values
 ('handicap_ft','הפרשי שערים',true),
 ('total_goals_2_5','מעל / מתחת 2.5 שערים',true),
 ('btts','שתי הקבוצות יבקיעו',true)
on conflict (market_key) do nothing;

alter table public.bets add column if not exists market_id bigint references public.winner_markets(id) on delete set null;
alter table public.bets add column if not exists market_key text;
alter table public.bets add column if not exists market_label text;
alter table public.bets add column if not exists market_selection text;
alter table public.bets add column if not exists market_outcome_label text;
alter table public.bets add column if not exists market_line numeric(8,2);

create or replace function public.get_market_display_settings()
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_object_agg(market_key, enabled), '{}'::jsonb)
  from public.market_display_settings;
$$;
revoke all on function public.get_market_display_settings() from public, anon;
grant execute on function public.get_market_display_settings() to authenticated;

create or replace function public.admin_get_market_settings()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v jsonb;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'key',market_key,'label',label,'enabled',enabled
  ) order by case market_key when 'handicap_ft' then 1 when 'total_goals_2_5' then 2 else 3 end),'[]'::jsonb)
  into v from public.market_display_settings;
  return v;
end; $$;
revoke all on function public.admin_get_market_settings() from public, anon;
grant execute on function public.admin_get_market_settings() to authenticated;

create or replace function public.admin_set_market_setting(p_market_key text,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_label text;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  if p_market_key not in ('handicap_ft','total_goals_2_5','btts') then raise exception 'סוג שוק לא מוכר'; end if;
  update public.market_display_settings
     set enabled=coalesce(p_enabled,false), updated_at=now()
   where market_key=p_market_key returning label into v_label;
  if not found then raise exception 'הגדרת השוק לא נמצאה'; end if;
  return jsonb_build_object('key',p_market_key,'label',v_label,'enabled',p_enabled);
end; $$;
revoke all on function public.admin_set_market_setting(text,boolean) from public, anon;
grant execute on function public.admin_set_market_setting(text,boolean) to authenticated;

-- Receives the supported full-time markets from the Winner browser extension.
-- Matching is against existing SportStats fixtures; this function never creates games.
create or replace function public.import_winner_markets(p_markets jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  item jsonb;
  outcome jsonb;
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
  v_selection text;
  v_label text;
  v_price numeric;
  v_received integer := 0;
  v_processed integer := 0;
  v_matched integer := 0;
  v_saved integer := 0;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if jsonb_typeof(p_markets) <> 'array' then raise exception 'markets must be an array'; end if;
  v_received := jsonb_array_length(p_markets);

  for item in select value from jsonb_array_elements(p_markets)
  loop
    v_market_key := case
      when item->>'mop' = '30002' and coalesce(item->>'mp','') ilike '%הימור יתרון%' then 'handicap_ft'
      when item->>'mop' = '50002' and coalesce(item->>'mp','') ilike '%מעל/מתחת שערים%' then 'total_goals_2_5'
      when item->>'mop' = '400002' then 'btts'
      else null
    end;
    if v_market_key is null then continue; end if;

    v_desc := nullif(trim(item->>'desc'),'');
    v_source_id := nullif(item->>'mId','');
    v_hhmm := lpad(coalesce(item->>'m_hour',''),4,'0');
    if v_desc is null or v_source_id is null or length(coalesce(item->>'e_date','')) <> 6
       or v_hhmm !~ '^[0-2][0-9][0-5][0-9]$' then continue; end if;
    v_home := nullif(trim(split_part(v_desc,' - ',1)),'');
    v_away := nullif(trim(split_part(v_desc,' - ',2)),'');
    if v_home is null or v_away is null then continue; end if;
    begin
      v_date := to_date(item->>'e_date','YYMMDD');
      v_kickoff := (v_date + make_time(substr(v_hhmm,1,2)::integer,substr(v_hhmm,3,2)::integer,0)) at time zone 'Asia/Jerusalem';
    exception when others then continue;
    end;

    select g.id into v_game_id
      from public.games g
     where (lower(trim(g.home_team))=lower(v_home) or lower(trim(coalesce(g.sportstats_api_home_name,'')))=lower(v_home))
       and (lower(trim(g.away_team))=lower(v_away) or lower(trim(coalesce(g.sportstats_api_away_name,'')))=lower(v_away))
       and abs(extract(epoch from (g.match_time-v_kickoff))) <= 1800
       and g.status='upcoming'
     order by abs(extract(epoch from (g.match_time-v_kickoff)))
     limit 1;
    if v_game_id is null then continue; end if;
    v_matched := v_matched + 1;

    v_market_label := case v_market_key
      when 'handicap_ft' then 'הפרשי שערים'
      when 'total_goals_2_5' then 'מעל / מתחת 2.5 שערים'
      else 'שתי הקבוצות יבקיעו'
    end;

    v_home_desc := null;
    if v_market_key='handicap_ft' then
      select o->>'desc' into v_home_desc
      from jsonb_array_elements(coalesce(item->'outcomes','[]'::jsonb)) o
      where lower(coalesce(o->>'desc','')) like '%'||lower(v_home)||'%'
      limit 1;
      if v_home_desc is null then continue; end if;
      v_line := nullif(substring(replace(v_home_desc,'−','-') from '([+-]?[0-9]+([.][0-9]+)?)'),'')::numeric;
      if v_line is null then continue; end if;
    else
      v_line := case when v_market_key='total_goals_2_5' then 2.5 else null end;
    end if;

    select jsonb_agg(jsonb_build_object(
      'selection', mapped.selection,
      'label', mapped.label,
      'price', mapped.price
    ) order by mapped.ordinality)
    into v_outcomes
    from (
      select x.ordinality,
        x.value->>'desc' as label,
        (x.value->>'price')::numeric as price,
        case
          when v_market_key='handicap_ft' and lower(coalesce(x.value->>'desc','')) like '%'||lower(v_home)||'%' then 'home'
          when v_market_key='handicap_ft' and lower(coalesce(x.value->>'desc','')) like '%'||lower(v_away)||'%' then 'away'
          when v_market_key='handicap_ft' and (upper(coalesce(x.value->>'desc','')) like '%X%' or coalesce(x.value->>'desc','') like '%תיקו%') then 'draw'
          when v_market_key='total_goals_2_5' and coalesce(x.value->>'desc','') like '%מעל%' then 'over'
          when v_market_key='total_goals_2_5' and coalesce(x.value->>'desc','') like '%מתחת%' then 'under'
          when v_market_key='btts' and coalesce(x.value->>'desc','') like '%כן%' then 'yes'
          when v_market_key='btts' and coalesce(x.value->>'desc','') like '%לא%' then 'no'
          else null
        end as selection
      from jsonb_array_elements(coalesce(item->'outcomes','[]'::jsonb)) with ordinality as x(value,ordinality)
      where coalesce(x.value->>'price','') ~ '^[0-9]+([.][0-9]+)?$'
    ) mapped
    where mapped.selection is not null and mapped.price between 1.01 and 999.99;

    if v_outcomes is null or jsonb_array_length(v_outcomes)<2 then continue; end if;
    v_processed := v_processed + 1;

    insert into public.winner_markets(
      game_id,source_market_id,source_event_id,market_key,market_label,line,outcomes,active,updated_at
    ) values (
      v_game_id,v_source_id,nullif(item->>'eId',''),v_market_key,v_market_label,v_line,v_outcomes,true,now()
    )
    on conflict (game_id,source_market_id) do update set
      source_event_id=excluded.source_event_id,
      market_key=excluded.market_key,
      market_label=excluded.market_label,
      line=excluded.line,
      outcomes=excluded.outcomes,
      active=true,
      updated_at=now();
    v_saved := v_saved + 1;
  end loop;

  return jsonb_build_object('received',v_received,'matched',v_matched,'processed',v_processed,'saved',v_saved);
end; $$;
revoke all on function public.import_winner_markets(jsonb) from public, anon;
grant execute on function public.import_winner_markets(jsonb) to authenticated;

create or replace function public.place_market_bet(
  p_market_id bigint,
  p_selection text,
  p_amount numeric
) returns jsonb language plpgsql security definer set search_path=public as $$
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
end; $$;
revoke all on function public.place_market_bet(bigint,text,numeric) from public, anon;
grant execute on function public.place_market_bet(bigint,text,numeric) to authenticated;

-- Settle Winner-market singles from the confirmed 90-minute score.
create or replace function public.settle_winner_market_bets()
returns trigger language plpgsql security definer set search_path=public as $$
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
      v_winning_selection := case when new.home_score+new.away_score>2.5 then 'over' else 'under' end;
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
end; $$;

drop trigger if exists settle_winner_market_bets_trigger on public.games;
create trigger settle_winner_market_bets_trigger
after update of status,home_score,away_score,result_confirmed on public.games
for each row execute function public.settle_winner_market_bets();

do $
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime')
     and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='winner_markets') then
    alter publication supabase_realtime add table public.winner_markets;
  end if;
end $;

notify pgrst,'reload schema';
