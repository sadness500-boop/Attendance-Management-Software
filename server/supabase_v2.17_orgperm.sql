-- =====================================================================
--  Attendance Management Software · v2.17 조직별 권한(수정 / 보기만) 따로 주기
--  예) 동부지사 = ✏️ 수정,  서부지사 · 남부지사 · 중부지사 = 👁 보기만
--  · 관리 범위에 level "multi" 추가:  {"level":"multi","rules":[{"t":"org","id":"…","perm":"edit|view|none"},
--                                       {"t":"site","id":"…","perm":"…"}], "rest":"none|view"}
--  · 사업장 권한 = 그 사업장 규칙 → 가장 가까운 상위 조직 규칙 → 「그 외 모든 회사·조직」(rest) 순서로 결정
--    (새로 만든 회사·조직·사업장도 상위 조직 규칙을 그대로 따르고, 규칙이 없으면 rest 를 따름)
--  · 저장은 그 사업장 권한이 「수정」일 때만 서버가 허용
--  ※ supabase_setup.sql → v2.15_scope → v2.16_live 를 실행한 서버에 "추가로 한 번" 실행하세요.
--    여러 번 실행해도 안전합니다.  Designed & Developed by Rat Rae Choi
-- =====================================================================

-- 1) 조직의 상위 조직 목록(자기 자신 → 부모 → … → 최상위)
create or replace function public._org_chain(p_org text) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare b jsonb; cur text := p_org; out text[] := '{}'; n int := 0;
begin
  select v into b from public.shared_data where k = 'base';
  while cur is not null and cur <> '' and n < 30 loop
    if cur = any(out) then exit; end if;
    out := out || cur;
    select o->>'parent' into cur from jsonb_array_elements(coalesce(b->'orgs','[]'::jsonb)) o where o->>'id' = cur limit 1;
    n := n + 1;
  end loop;
  return out;
end $$;

-- 2) 이 사업장에 대한 내 권한: 'edit' / 'view' / null(범위 밖)
create or replace function public._site_perm(p_scope jsonb, p_site text, p_org text) returns text
language plpgsql stable security definer set search_path = public as $$
declare lv text := coalesce(p_scope->>'level',''); pv text := case when p_scope->>'perm' = 'view' then 'view' else 'edit' end;
        rules jsonb := coalesce(p_scope->'rules','[]'::jsonb); r jsonb; o text;
begin
  if lv = 'all'  then return pv; end if;
  if lv = 'site' then return case when coalesce(p_scope->'sites','[]'::jsonb) ? p_site then pv end; end if;
  if lv = 'org'  then return case when public._org_in_scope(p_scope, p_org) then pv end; end if;
  if lv = 'multi' then
    select x into r from jsonb_array_elements(rules) x where x->>'t' = 'site' and x->>'id' = p_site limit 1;
    if r is not null then return case when r->>'perm' in ('edit','view') then r->>'perm' end; end if;
    foreach o in array public._org_chain(p_org) loop
      select x into r from jsonb_array_elements(rules) x where x->>'t' = 'org' and x->>'id' = o limit 1;
      if r is not null then return case when r->>'perm' in ('edit','view') then r->>'perm' end; end if;
    end loop;
    return case when p_scope->>'rest' = 'view' then 'view' end;
  end if;
  return null;
end $$;

-- 3) 볼 수 있는지(공유 근태 받기에 사용) = 권한이 있으면
create or replace function public._site_allowed(p_scope jsonb, p_site text, p_org text) returns boolean
language sql stable security definer set search_path = public as $$
  select public._site_perm(p_scope, p_site, p_org) is not null
$$;

-- 4) 하나라도 고칠 수 있는지
create or replace function public._scope_can_edit(p_scope jsonb) returns boolean
language sql immutable as $$
  select case when p_scope->>'level' = 'multi'
              then exists (select 1 from jsonb_array_elements(coalesce(p_scope->'rules','[]'::jsonb)) x where x->>'perm' = 'edit')
              else coalesce(p_scope->>'perm', 'edit') <> 'view' end
$$;

-- 5) 저장: 사업장마다 「수정」 권한일 때만
create or replace function public.shared_put(p_k text, p_v jsonb, p_expect timestamptz, p_device text) returns json
language plpgsql security definer set search_path = public as $$
declare sc jsonb; ts timestamptz := clock_timestamp(); cur public.shared_data; sid text;
begin
  if not public.can_use() then raise exception '사용 권한이 없습니다'; end if;
  sc := public.my_scope();
  if coalesce(sc->>'level','') = '' then raise exception '공유 근태 관리 범위가 없습니다'; end if;
  if not public._scope_can_edit(sc) then raise exception '보기 전용 권한입니다 — 근태를 고칠 수 없습니다'; end if;
  if length(coalesce(p_v::text,'')) > 20000000 then raise exception '데이터가 너무 큽니다'; end if;

  select * into cur from public.shared_data where k = p_k for update;

  if p_k = 'base' then
    if sc->>'level' <> 'all' or coalesce(sc->>'perm','edit') = 'view' then raise exception '조직·근무조 코드 등 공통 설정은 전체 권한만 저장할 수 있습니다'; end if;
  elsif p_k like 'site:%' then
    sid := substr(p_k, 6);
    if cur.k is not null and coalesce(public._site_perm(sc, sid, cur.v->'site'->>'org'),'') <> 'edit' then raise exception '이 사업장은 보기만 할 수 있거나 관리 범위 밖입니다'; end if;
    if p_v is not null and coalesce(public._site_perm(sc, sid, p_v->'site'->>'org'),'') <> 'edit' then raise exception '이 사업장은 보기만 할 수 있거나 관리 범위 밖입니다'; end if;
  else
    raise exception '허용되지 않은 항목';
  end if;

  -- 버전 확인 (다른 사람이 먼저 고쳤으면 충돌로 돌려줌 → 앱이 합쳐서 다시 저장)
  if (cur.k is null and p_expect is not null) or (cur.k is not null and cur.updated_at is distinct from p_expect) then
    return json_build_object('ok', false, 'conflict', true, 'k', p_k,
                             'v', cur.v, 'updated_at', cur.updated_at,
                             'by', coalesce((select coalesce(nullif(name,''), email) from public.profiles where id = cur.updated_by), ''));
  end if;

  if p_v is null then
    delete from public.shared_data where k = p_k;
  elsif cur.k is null then
    insert into public.shared_data (k, v, updated_at, updated_by) values (p_k, p_v, ts, auth.uid());
  else
    update public.shared_data set v = p_v, updated_at = ts, updated_by = auth.uid() where k = p_k;
  end if;
  return json_build_object('ok', true, 'k', p_k, 'updated_at', case when p_v is null then null else ts end);
end $$;


create or replace function public.shared_push(p_k text, p_v jsonb, p_device text) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare sc jsonb; ts timestamptz := clock_timestamp(); old jsonb; sid text;
begin
  if not public.can_use() then raise exception '사용 권한이 없습니다'; end if;
  sc := public.my_scope();
  if coalesce(sc->>'level','') = '' then raise exception '공유 근태 관리 범위가 없습니다'; end if;
  if not public._scope_can_edit(sc) then raise exception '보기 전용 권한입니다 — 근태를 고칠 수 없습니다'; end if;
  if length(coalesce(p_v::text,'')) > 20000000 then raise exception '데이터가 너무 큽니다'; end if;
  if p_k = 'base' then
    if sc->>'level' <> 'all' or coalesce(sc->>'perm','edit') = 'view' then raise exception '조직·근무조 코드 등 공통 설정은 전체 권한만 저장할 수 있습니다'; end if;
  elsif p_k like 'site:%' then
    sid := substr(p_k, 6);
    select v into old from public.shared_data where k = p_k;
    if old is not null and coalesce(public._site_perm(sc, sid, old->'site'->>'org'),'') <> 'edit' then raise exception '이 사업장은 보기만 할 수 있거나 관리 범위 밖입니다'; end if;
    if p_v is not null and coalesce(public._site_perm(sc, sid, p_v->'site'->>'org'),'') <> 'edit' then raise exception '이 사업장은 보기만 할 수 있거나 관리 범위 밖입니다'; end if;
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


-- 6) 관리 범위 지정에 조직별 권한(multi) 허용
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
    if coalesce(sc->>'level','') not in ('', 'all', 'org', 'site', 'multi') then raise exception '관리 범위 값 오류'; end if;
    if coalesce(sc->>'perm','edit') not in ('edit','view') then raise exception '권한 값 오류'; end if;
    if sc->>'level' = 'all' and me <> 'owner' then raise exception '전체 권한은 제작자만 줄 수 있습니다'; end if;
    if sc->>'level' = 'org' and coalesce(sc->>'org','') = '' then raise exception '조직을 고르세요'; end if;
    if sc->>'level' = 'site' and jsonb_array_length(coalesce(sc->'sites','[]'::jsonb)) = 0 then raise exception '사업장을 하나 이상 고르세요'; end if;
    if sc->>'level' = 'multi' then
      if jsonb_typeof(coalesce(sc->'rules','[]'::jsonb)) <> 'array' then raise exception '조직별 권한 값 오류'; end if;
      if exists (select 1 from jsonb_array_elements(coalesce(sc->'rules','[]'::jsonb)) x
                 where coalesce(x->>'t','') not in ('org','site') or coalesce(x->>'id','') = '' or coalesce(x->>'perm','') not in ('edit','view','none')) then
        raise exception '조직별 권한 값 오류'; end if;
      if coalesce(sc->>'rest','none') not in ('none','view') then raise exception '그 외 조직 권한은 「없음」 또는 「보기만」만 됩니다'; end if;
      if not exists (select 1 from jsonb_array_elements(coalesce(sc->'rules','[]'::jsonb)) x where x->>'perm' in ('edit','view'))
         and coalesce(sc->>'rest','none') = 'none' then raise exception '조직을 하나 이상 「수정」 또는 「보기만」으로 정하세요'; end if;
    end if;
    update public.profiles set scope = sc, force_logout_at = case when t.status = 'active' then now() else force_logout_at end where id = p_user;
    perform public._admin_log(p_user, 'scope', coalesce(sc->>'label', sc::text)
      || case when coalesce(sc->>'level','') in ('', 'multi') then '' when sc->>'perm' = 'view' then ' · 보기만' else ' · 수정 가능' end);
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


revoke execute on function public._org_chain(text) from public, anon;
revoke execute on function public._site_perm(jsonb, text, text) from public, anon;
revoke execute on function public._site_allowed(jsonb, text, text) from public, anon;
grant execute on function public.shared_put(text, jsonb, timestamptz, text) to authenticated;
grant execute on function public.shared_push(text, jsonb, text) to authenticated;
grant execute on function public.admin_update_user(uuid, text, text) to authenticated;
