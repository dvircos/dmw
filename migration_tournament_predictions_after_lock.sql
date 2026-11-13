create or replace function public.tournament_save_predictions(p_tournament_id uuid,p_predictions jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_item jsonb; v_game_id bigint; v_selection text; v_saved integer:=0;
begin
  if auth.uid() is null then raise exception 'יש להתחבר'; end if;
  if jsonb_typeof(p_predictions)<>'array' then raise exception 'מבנה ניחושים לא תקין'; end if;
  if not exists(select 1 from public.tournament_participants where tournament_id=p_tournament_id and user_id=auth.uid()) then raise exception 'צריך להצטרף לטורניר קודם'; end if;
  if not exists(select 1 from public.tournaments where id=p_tournament_id and status in ('open','locked')) then raise exception 'הטורניר אינו פעיל'; end if;
  for v_item in select value from jsonb_array_elements(p_predictions) loop
    v_game_id := (v_item->>'game_id')::bigint;
    v_selection := v_item->>'selection';
    if v_selection not in ('1','X','2') then raise exception 'ניחוש לא תקין'; end if;
    if not exists(select 1 from public.tournament_games tg join public.games g on g.id=tg.game_id where tg.tournament_id=p_tournament_id and tg.game_id=v_game_id and g.status='upcoming' and g.match_time>now()) then raise exception 'אי אפשר לנחש משחק שכבר התחיל'; end if;
    insert into public.tournament_predictions(tournament_id,game_id,user_id,selection)
    values(p_tournament_id,v_game_id,auth.uid(),v_selection)
    on conflict(tournament_id,game_id,user_id) do update set selection=excluded.selection,updated_at=now();
    v_saved:=v_saved+1;
  end loop;
  return jsonb_build_object('saved',v_saved);
end; $$;
revoke all on function public.tournament_save_predictions(uuid,jsonb) from public,anon;
grant execute on function public.tournament_save_predictions(uuid,jsonb) to authenticated;
notify pgrst, 'reload schema';