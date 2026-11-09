-- =====================================================================
--  Attendance Management Software · v2.15 관리 범위(권한) · 공유 근태
--  회사 · 지사(조직) · 사업장 단위로 사용자에게 근태 관리 권한을 줍니다.
--  ※ 이미 supabase_setup.sql 을 실행한 서버에 "추가로 한 번" 실행하세요.
--    여러 번 실행해도 안전합니다.  Designed & Developed by Rat Rae Choi
-- =====================================================================

-- 1) 사용자별 관리 범위
--    {}                                  → 공유 안 함(개인 자료, 예전 방식)
--    {"level":"all"}                     → 전체(모든 회사·지사·사업장)
--    {"level":"org","org":"O02",...}     → 그 조직(회사·본부·지사·지점…) 아래 모든 사업장
--    {"level":"site","sites":["S01",…]}  → 고른 사업장만
alter table public.profiles add column if not exists scope jsonb not null default '{}'::jsonb;

-- 2) 공유 근태 저장소 — 'base'(조직·근무조 코드·근태기호·공휴일 등) + 'site:사업장ID'(사업장 정보·인원·근태)
create table if not exists public.shared_data (
  k          text primary key,
  v          jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.shared_data enable row level security;   -- 정책 없음 → 아래 함수로만 읽기·쓰기

-- 3) 범위 계산
create or replace function public.my_scope() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when p.role = 'owner' then '{"level":"all"}'::jsonb else coalesce(p.scope, '{}'::jsonb) end
  from public.profiles p where p.id = auth.uid()
$$;

create or replace function public._org_in_scope(p_scope jsonb, p_org text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare b jsonb; cur text := p_org; target text := p_scope->>'org'; n int := 0;
begin
  if p_scope->>'level' = 'all' then return true; end if;
  if coalesce(p_scope->>'level','') <> 'org' or target is null or cur is null or cur = '' then return false; end if;
  select v into b from public.shared_data where k = 'base';
  while cur is not null and cur <> '' and n < 30 loop
    if cur = target then return true; end if;
    cur := null;
    select o->>'parent' into cur from jsonb_array_elements(coalesce(b->'orgs','[]'::jsonb)) o where o->>'id' = p_org limit 1;
    p_org := cur; n := n + 1;
  end loop;
  return false;
end $$;

create or replace function public._site_allowed(p_scope jsonb, p_site text, p_org text) returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  case coalesce(p_scope->>'level','')
    when 'all'  then return true;
    when 'site' then return coalesce(p_scope->'sites','[]'::jsonb) ? p_site;
    when 'org'  then return public._org_in_scope(p_scope, p_org);
    else return false;
  end case;
end $$;

-- 4) 공유 근태 읽기 · 쓰기
create or replace function public.shared_pull() returns json
language plpgsql stable security definer set search_path = public as $$
declare sc jsonb;
begin
  if not public.can_use() then raise exception '사용 권한이 없습니다'; end if;
  sc := public.my_scope();
  if coalesce(sc->>'level','') = '' then raise exception '공유 근태 관리 범위가 없습니다'; end if;
  return json_build_object('scope', sc, 'items', coalesce((
    select json_agg(json_build_object('k', d.k, 'v', d.v, 'updated_at', d.updated_at))
    from public.shared_data d
    where d.k = 'base' or (d.k like 'site:%' and public._site_allowed(sc, substr(d.k, 6), d.v->'site'->>'org'))
  ), '[]'::json));
end $$;

create or replace function public.shared_push(p_k text, p_v jsonb, p_device text) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare sc jsonb; ts timestamptz := now(); old jsonb; sid text;
begin
  if not public.can_use() then raise exception '사용 권한이 없습니다'; end if;
  sc := public.my_scope();
  if coalesce(sc->>'level','') = '' then raise exception '공유 근태 관리 범위가 없습니다'; end if;
  if length(coalesce(p_v::text,'')) > 20000000 then raise exception '데이터가 너무 큽니다'; end if;
  if p_k = 'base' then
    if sc->>'level' <> 'all' then raise exception '조직·근무조 코드 등 공통 설정은 전체 권한만 저장할 수 있습니다'; end if;
  elsif p_k like 'site:%' then
    sid := substr(p_k, 6);
    select v into old from public.shared_data where k = p_k;
    if old is not null and not public._site_allowed(sc, sid, old->'site'->>'org') then raise exception '이 사업장의 관리 권한이 없습니다'; end if;
    if p_v is not null and not public._site_allowed(sc, sid, p_v->'site'->>'org') then raise exception '이 사업장의 관리 권한이 없습니다'; end if;
  else
    raise exception '허용되지 않은 항목';
  end if;
  if p_v is null then
    delete from public.shared_data where k = p_k;
  else
    insert into public.shared_data (k, v, updated_at, updated_by) values (p_k, p_v, ts, auth.uid())
    on conflict (k) do update set v = excluded.v, updated_at = ts, updated_by = auth.uid();
  end if;
  return ts;
end $$;

-- 5) 로그인 확인 결과에 범위 포함
create or replace function public.client_checkin(
  p_device text, p_device_name text, p_ua text, p_event text, p_login_at timestamptz
) returns json
language plpgsql security definer set search_path = public as $$
declare pr public.profiles; s public.app_settings; d public.devices; reason text := 'ok'; ip text := public.client_ip();
begin
  if auth.uid() is null then return json_build_object('ok', false, 'reason', 'no_session'); end if;
  select * into pr from public.profiles where id = auth.uid();
  if not found then return json_build_object('ok', false, 'reason', 'no_profile'); end if;
  select * into s from public.app_settings where id = 1;

  insert into public.devices (id, user_id, name, ua, last_ip)
  values (coalesce(p_device,''), pr.id, coalesce(p_device_name,''), left(coalesce(p_ua,''), 300), ip)
  on conflict (user_id, id) do update
    set last_seen = now(), ua = excluded.ua, last_ip = excluded.last_ip,
        name = case when excluded.name <> '' then excluded.name else public.devices.name end
  returning * into d;

  if pr.status = 'pending' then reason := 'pending';
  elsif pr.status = 'suspended' then reason := 'suspended';
  elsif pr.expires_at is not null and pr.expires_at < (now() at time zone 'Asia/Seoul')::date then reason := 'expired';
  elsif d.blocked then reason := 'device_blocked';
  elsif pr.force_logout_at is not null and p_login_at is not null and pr.force_logout_at > p_login_at then reason := 'forced';
  elsif s.global_lock and pr.role not in ('owner','admin') then reason := 'locked';
  end if;

  if p_event = 'login' then
    insert into public.login_logs (user_id, email, event, device_id, device, ip, detail)
    values (pr.id, pr.email, case when reason = 'ok' then 'login' else 'blocked' end,
            coalesce(p_device,''), coalesce(nullif(p_device_name,''), left(coalesce(p_ua,''),120)), ip,
            case when reason = 'ok' then '' else reason end);
    if reason = 'ok' then update public.profiles set last_login_at = now(), last_seen_at = now() where id = pr.id; end if;
  elsif reason = 'forced' then
    insert into public.login_logs (user_id, email, event, device_id, device, ip, detail)
    values (pr.id, pr.email, 'forced', coalesce(p_device,''), coalesce(p_device_name,''), ip, '관리자 강제 로그아웃');
  else
    update public.profiles set last_seen_at = now() where id = pr.id;
  end if;

  return json_build_object(
    'ok', reason = 'ok', 'reason', reason,
    'lock_message', s.lock_message,
    'profile', json_build_object('id', pr.id, 'email', pr.email, 'name', pr.name, 'phone', pr.phone, 'dept', pr.dept,
                                 'role', pr.role, 'status', pr.status, 'expires_at', pr.expires_at,
                                 'must_change_pw', pr.must_change_pw,
                                 'scope', case when pr.role = 'owner' then '{"level":"all"}'::jsonb else coalesce(pr.scope,'{}'::jsonb) end));
end $$;

-- 6) 관리자 목록에 범위 포함
drop function if exists public.admin_list_users();
create or replace function public.admin_list_users() returns table (
  id uuid, email text, name text, phone text, dept text, role text, status text, expires_at date,
  must_change_pw boolean, memo text, created_at timestamptz, approved_at timestamptz,
  last_login_at timestamptz, last_seen_at timestamptz, device_count bigint, fail_7d bigint, scope jsonb
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '권한이 없습니다'; end if;
  return query
  select p.id, p.email, p.name, p.phone, p.dept, p.role, p.status, p.expires_at, p.must_change_pw, p.memo,
         p.created_at, p.approved_at, p.last_login_at, p.last_seen_at,
         (select count(*) from public.devices d where d.user_id = p.id),
         (select count(*) from public.login_logs l where l.email = p.email and l.event = 'login_fail'
            and l.created_at > now() - interval '7 days'),
         case when p.role = 'owner' then '{"level":"all"}'::jsonb else coalesce(p.scope,'{}'::jsonb) end
  from public.profiles p
  order by case p.status when 'pending' then 0 when 'active' then 1 else 2 end, p.created_at desc;
end $$;

-- 7) 사용자 변경에 'scope'(관리 범위) 추가
create or replace function public.admin_update_user(p_user uuid, p_action text, p_value text default null) returns void
language plpgsql security definer set search_path = public as $$
declare t public.profiles; me text := public.my_role(); s public.app_settings; sc jsonb;
begin
  if me not in ('owner','admin') or me is null then raise exception '권한이 없습니다'; end if;
  select * into t from public.profiles where id = p_user;
  if not found then raise exception '사용자를 찾을 수 없습니다'; end if;
  if t.role = 'owner' and p_action <> 'memo' then raise exception '제작자(owner) 계정은 변경할 수 없습니다'; end if;
  if t.role = 'admin' and me <> 'owner' then raise exception '관리자 계정은 제작자만 변경할 수 있습니다'; end if;
  select * into s from public.app_settings where id = 1;

  if p_action = 'approve' then
    update public.profiles set status = 'active', approved_at = now(),
      expires_at = case when expires_at is null and s.default_days > 0
                        then (now() at time zone 'Asia/Seoul')::date + s.default_days else expires_at end
    where id = p_user;
  elsif p_action = 'suspend' then
    update public.profiles set status = 'suspended', force_logout_at = now() where id = p_user;
  elsif p_action = 'activate' then
    update public.profiles set status = 'active', approved_at = coalesce(approved_at, now()) where id = p_user;
  elsif p_action = 'expires' then
    update public.profiles set expires_at = nullif(p_value, '')::date where id = p_user;
  elsif p_action = 'role' then
    if me <> 'owner' then raise exception '역할 변경은 제작자만 할 수 있습니다'; end if;
    if p_value not in ('admin','user') then raise exception '역할 값 오류'; end if;
    update public.profiles set role = p_value where id = p_user;
  elsif p_action = 'scope' then
    sc := coalesce(nullif(p_value, ''), '{}')::jsonb;
    if coalesce(sc->>'level','') not in ('', 'all', 'org', 'site') then raise exception '관리 범위 값 오류'; end if;
    if sc->>'level' = 'all' and me <> 'owner' then raise exception '전체 권한은 제작자만 줄 수 있습니다'; end if;
    if sc->>'level' = 'org' and coalesce(sc->>'org','') = '' then raise exception '조직을 고르세요'; end if;
    if sc->>'level' = 'site' and jsonb_array_length(coalesce(sc->'sites','[]'::jsonb)) = 0 then raise exception '사업장을 하나 이상 고르세요'; end if;
    update public.profiles set scope = sc, force_logout_at = case when t.status = 'active' then now() else force_logout_at end where id = p_user;
    perform public._admin_log(p_user, 'scope', coalesce(sc->>'label', sc::text));
    return;
  elsif p_action = 'memo' then
    update public.profiles set memo = coalesce(p_value, '') where id = p_user;
  elsif p_action = 'force_logout' then
    update public.profiles set force_logout_at = now() where id = p_user;
  elsif p_action = 'delete' then
    if me <> 'owner' then raise exception '계정 삭제는 제작자만 할 수 있습니다'; end if;
    perform public._admin_log(p_user, 'delete', t.email);
    delete from auth.users where id = p_user;
    return;
  else
    raise exception '알 수 없는 작업: %', p_action;
  end if;
  perform public._admin_log(p_user, p_action, coalesce(p_value, ''));
end $$;

revoke all on function public.admin_list_users() from public, anon;
revoke all on function public.shared_pull() from public, anon;
revoke all on function public.shared_push(text, jsonb, text) from public, anon;
revoke all on function public.my_scope() from public, anon;
grant execute on function public.my_scope() to authenticated;
grant execute on function public.shared_pull() to authenticated;
grant execute on function public.shared_push(text, jsonb, text) to authenticated;
grant execute on function public.admin_list_users() to authenticated;
grant execute on function public.admin_update_user(uuid, text, text) to authenticated;
grant execute on function public.client_checkin(text, text, text, text, timestamptz) to authenticated;
revoke execute on function public._org_in_scope(jsonb, text) from public, anon;
revoke execute on function public._site_allowed(jsonb, text, text) from public, anon;

-- 완료! "Success. No rows returned" 가 나오면 정상입니다.
