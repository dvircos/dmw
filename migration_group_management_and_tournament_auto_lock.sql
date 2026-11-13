begin;
create or replace function public.groups_list()
returns jsonb language plpgsql stable security definer set search_path=public as $function$
declare v jsonb;
begin
 if auth.uid() is null then raise exception 'יש להתחבר'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',g.id,'name',g.name,'is_public',g.is_public,
   'is_member',(g.id='00000000-0000-0000-0000-000000000001'::uuid or exists(select 1 from public.app_group_members m where m.group_id=g.id and m.user_id=auth.uid())),
   'is_owner',(g.created_by=auth.uid()),
   'member_count',(select count(*) from public.app_group_members m where m.group_id=g.id),
   'invite_code',case when g.created_by=auth.uid() or exists(select 1 from public.app_group_members m where m.group_id=g.id and m.user_id=auth.uid()) then g.invite_code else null end
 ) order by (g.id='00000000-0000-0000-0000-000000000001'::uuid) desc,g.name),'[]'::jsonb)
 into v from public.app_groups g
 where g.id='00000000-0000-0000-0000-000000000001'::uuid or g.is_public=true
    or exists(select 1 from public.app_group_members m where m.group_id=g.id and m.user_id=auth.uid())
    or g.created_by=auth.uid();
 return v;
end; $function$;
create or replace function public.groups_leave(p_group_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $function$
begin
 if auth.uid() is null then raise exception 'יש להתחבר'; end if;
 if p_group_id='00000000-0000-0000-0000-000000000001'::uuid then raise exception 'אי אפשר לצאת מקבוצת כולם'; end if;
 if not exists(select 1 from public.app_group_members where group_id=p_group_id and user_id=auth.uid()) then raise exception 'אינך חבר בקבוצה'; end if;
 if exists(select 1 from public.app_groups where id=p_group_id and created_by=auth.uid()) then raise exception 'מנהל הקבוצה לא יכול לצאת ממנה. אפשר למחוק את הקבוצה במקום זאת'; end if;
 delete from public.app_group_members where group_id=p_group_id and user_id=auth.uid();
 return jsonb_build_object('left',true,'group_id',p_group_id);
end; $function$;
create or replace function public.groups_update(p_group_id uuid,p_name text)
returns jsonb language plpgsql security definer set search_path=public as $function$
declare v_name text:=btrim(coalesce(p_name,''));
begin
 if auth.uid() is null then raise exception 'יש להתחבר'; end if;
 if char_length(v_name) not between 2 and 40 then raise exception 'שם הקבוצה חייב להכיל 2 עד 40 תווים'; end if;
 update public.app_groups set name=v_name where id=p_group_id and created_by=auth.uid()
   and id<>'00000000-0000-0000-0000-000000000001'::uuid;
 if not found then raise exception 'רק מנהל הקבוצה יכול לשנות את שמה'; end if;
 return jsonb_build_object('updated',true,'group_id',p_group_id,'name',v_name);
end; $function$;
create or replace function public.groups_delete(p_group_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $function$
begin
 if auth.uid() is null then raise exception 'יש להתחבר'; end if;
 if p_group_id='00000000-0000-0000-0000-000000000001'::uuid then raise exception 'אי אפשר למחוק את קבוצת כולם'; end if;
 delete from public.app_groups where id=p_group_id and created_by=auth.uid();
 if not found then raise exception 'רק מנהל הקבוצה יכול למחוק אותה'; end if;
 return jsonb_build_object('deleted',true,'group_id',p_group_id);
end; $function$;
revoke all on function public.groups_leave(uuid) from public,anon;
revoke all on function public.groups_update(uuid,text) from public,anon;
revoke all on function public.groups_delete(uuid) from public,anon;
grant execute on function public.groups_leave(uuid) to authenticated;
grant execute on function public.groups_update(uuid,text) to authenticated;
grant execute on function public.groups_delete(uuid) to authenticated;
do $block$
declare v_job bigint;
begin
 if not exists(select 1 from pg_extension where extname='pg_cron') then raise exception 'pg_cron is required'; end if;
 for v_job in select jobid from cron.job where jobname='dmw-auto-lock-tournaments' loop perform cron.unschedule(v_job); end loop;
 perform cron.schedule('dmw-auto-lock-tournaments','* * * * *',
 $cmd$update public.tournaments set status='locked' where status='open' and registration_closes_at is not null and registration_closes_at<=now();$cmd$);
end; $block$;
update public.tournaments set status='locked' where status='open' and registration_closes_at is not null and registration_closes_at<=now();
notify pgrst,'reload schema';
commit;