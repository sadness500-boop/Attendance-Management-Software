-- =====================================================================
--  Attendance Management Software · 제작자 관리(로그인·권한·동기화) 서버 설정
--  Designed & Developed by Rat Rae Choi
--
--  사용법: Supabase › SQL Editor › New query 에 이 파일 전체를 붙여넣고 Run.
--  ★ 딱 한 곳만 고치세요: 아래 'OWNER_EMAIL' 줄의 이메일을 제작자 본인 이메일로.
--  여러 번 실행해도 안전합니다(이미 있는 것은 건너뜀·갱신).
-- =====================================================================

-- ---------- 0. 앱 전체 설정 ----------
create table if not exists public.app_settings (
  id              int primary key default 1 check (id = 1),
  owner_email     text not null,
  signup_open     boolean not null default true,   -- 가입 신청 받기
  require_approval boolean not null default true,  -- 가입 후 제작자 승인 필요
  global_lock     boolean not null default false,  -- 앱 전체 잠금(제작자·관리자 제외)
  lock_message    text not null default '현재 프로그램 점검 중입니다. 잠시 후 이용해 주세요.',
  default_days    int  not null default 0,         -- 승인 시 기본 사용기간(일) · 0 = 무기한
  updated_at      timestamptz not null default now()
);

insert into public.app_settings (id, owner_email)
values (1, lower('OWNER_EMAIL@example.com'))          -- ★ 여기를 제작자 이메일로 바꾸세요
on conflict (id) do update set owner_email = excluded.owner_email;

-- ---------- 1. 사용자 프로필(역할·상태·사용기한) ----------
create table if not exists public.profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  email           text not null,
  name            text not null default '',
  phone           text not null default '',
  dept            text not null default '',
  role            text not null default 'user'    check (role in ('owner','admin','user')),
  status          text not null default 'pending' check (status in ('pending','active','suspended')),
  expires_at      date,                            -- 사용기한(이 날까지 사용) · 비우면 무기한
  must_change_pw  boolean not null default false,  -- 임시 비밀번호 발급 후 변경 강제
  force_logout_at timestamptz,                     -- 이 시각 이전 로그인은 모두 로그아웃
  memo            text not null default '',
  created_at      timestamptz not null default now(),
  approved_at     timestamptz,
  last_login_at   timestamptz,
  last_seen_at    timestamptz
);

-- ---------- 2. 기기 ----------
create table if not exists public.devices (
  id          text not null,                       -- 기기 고유번호(앱이 만든 값)
  user_id     uuid not null references public.profiles(id) on delete cascade,
  name        text not null default '',            -- 예: 자택 PC, 회사 PC, 휴대폰
  ua          text not null default '',
  blocked     boolean not null default false,
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  last_ip     text not null default '',
  primary key (user_id, id)
);

-- ---------- 3. 접속 기록 ----------
create table if not exists public.login_logs (
  id         bigserial primary key,
  user_id    uuid references public.profiles(id) on delete set null,
  email      text not null default '',
  event      text not null,                        -- login / login_fail / logout / blocked / forced
  device_id  text not null default '',
  device     text not null default '',
  ip         text not null default '',
  detail     text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists login_logs_created_idx on public.login_logs (created_at desc);
create index if not exists login_logs_user_idx on public.login_logs (user_id, created_at desc);

-- ---------- 4. 관리 작업 기록 ----------
create table if not exists public.admin_logs (
  id         bigserial primary key,
  admin_id   uuid,
  admin_email text not null default '',
  target_email text not null default '',
  action     text not null,
  detail     text not null default '',
  created_at timestamptz not null default now()
);

-- ---------- 5. 사용자 데이터(여러 기기 동기화) ----------
create table if not exists public.user_data (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  k          text not null,                        -- ams_v1_state(근태 자료) / ams_v1_ui(화면 설정)
  v          jsonb,
  updated_at timestamptz not null default now(),
  device_id  text not null default '',
  primary key (user_id, k)
);

-- =====================================================================
--  도우미 함수
-- =====================================================================
create or replace function public.client_ip() returns text
language sql stable as $$
  select coalesce(split_part(nullif(current_setting('request.headers', true), '')::json->>'x-forwarded-for', ',', 1), '')
$$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and status = 'active'
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('owner','admin'), false)
$$;

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'owner', false)
$$;

-- 지금 이 사용자가 앱을 써도 되는가 (active + 기한 내)
create or replace function public.can_use() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.status = 'active'
      and (p.expires_at is null or p.expires_at >= (now() at time zone 'Asia/Seoul')::date)
  )
$$;

create or replace function public._admin_log(p_target uuid, p_action text, p_detail text) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.admin_logs (admin_id, admin_email, target_email, action, detail)
  values (auth.uid(),
          coalesce((select email from public.profiles where id = auth.uid()), ''),
          coalesce((select email from public.profiles where id = p_target), ''),
          p_action, coalesce(p_detail, ''));
end $$;

-- =====================================================================
--  가입 시 프로필 자동 생성 (제작자 이메일이면 owner·즉시 사용)
-- =====================================================================
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.app_settings; is_own boolean;
begin
  select * into s from public.app_settings where id = 1;
  is_own := lower(new.email) = lower(s.owner_email);
  insert into public.profiles (id, email, name, phone, dept, role, status, approved_at, expires_at)
  values (
    new.id, lower(new.email),
    coalesce(new.raw_user_meta_data->>'name', ''),
    coalesce(new.raw_user_meta_data->>'phone', ''),
    coalesce(new.raw_user_meta_data->>'dept', ''),
    case when is_own then 'owner' else 'user' end,
    case when is_own or not s.require_approval then 'active' else 'pending' end,
    case when is_own or not s.require_approval then now() end,
    case when not is_own and not s.require_approval and s.default_days > 0
         then (now() at time zone 'Asia/Seoul')::date + s.default_days end
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 이미 가입한 사람이 있으면 프로필 채우기 (이 SQL을 나중에 실행한 경우)
insert into public.profiles (id, email, name, role, status, approved_at)
select u.id, lower(u.email), coalesce(u.raw_user_meta_data->>'name',''),
       case when lower(u.email) = (select lower(owner_email) from public.app_settings) then 'owner' else 'user' end,
       case when lower(u.email) = (select lower(owner_email) from public.app_settings) then 'active' else 'pending' end,
       case when lower(u.email) = (select lower(owner_email) from public.app_settings) then now() end
from auth.users u
on conflict (id) do nothing;

-- 제작자 이메일 계정은 항상 owner·active 로 고정
update public.profiles set role = 'owner', status = 'active', approved_at = coalesce(approved_at, now())
where email = (select lower(owner_email) from public.app_settings);

-- =====================================================================
--  보안 규칙 (RLS) — 직접 테이블 접근은 최소로, 나머지는 함수로만
-- =====================================================================
alter table public.app_settings enable row level security;
alter table public.profiles     enable row level security;
alter table public.devices      enable row level security;
alter table public.login_logs   enable row level security;
alter table public.admin_logs   enable row level security;
alter table public.user_data    enable row level security;

drop policy if exists "본인 프로필 보기" on public.profiles;
create policy "본인 프로필 보기" on public.profiles for select
  using (id = auth.uid() or public.is_admin());

drop policy if exists "본인 데이터" on public.user_data;
create policy "본인 데이터" on public.user_data for all
  using (user_id = auth.uid() and public.can_use())
  with check (user_id = auth.uid() and public.can_use());

drop policy if exists "관리자 로그 보기" on public.login_logs;
create policy "관리자 로그 보기" on public.login_logs for select using (public.is_admin());
drop policy if exists "관리자 작업 보기" on public.admin_logs;
create policy "관리자 작업 보기" on public.admin_logs for select using (public.is_admin());
drop policy if exists "관리자 기기 보기" on public.devices;
create policy "관리자 기기 보기" on public.devices for select using (user_id = auth.uid() or public.is_admin());
-- app_settings 는 정책 없음 → 직접 접근 불가, 아래 함수로만 읽기·쓰기

-- =====================================================================
--  앱이 부르는 함수 (사용자용)
-- =====================================================================

-- 공개 설정(로그인 전 화면용)
create or replace function public.public_settings() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('signup_open', signup_open, 'require_approval', require_approval,
                           'global_lock', global_lock, 'lock_message', lock_message)
  from public.app_settings where id = 1
$$;

-- 접속 확인: 로그인 직후(p_event='login')와 앱을 다시 열 때(p_event='resume') 호출
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
                                 'must_change_pw', pr.must_change_pw));
end $$;

-- 로그인 실패 기록 (로그인 전이라 누구나 호출 가능)
create or replace function public.log_login_fail(p_email text, p_device text, p_device_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.login_logs (user_id, email, event, device_id, device, ip, detail)
  values ((select id from public.profiles where email = lower(p_email)), left(lower(coalesce(p_email,'')),120),
          'login_fail', left(coalesce(p_device,''),64), left(coalesce(p_device_name,''),120), public.client_ip(), '비밀번호 오류 등');
end $$;

create or replace function public.log_logout(p_device text, p_device_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.login_logs (user_id, email, event, device_id, device, ip)
  select id, email, 'logout', coalesce(p_device,''), coalesce(p_device_name,''), public.client_ip()
  from public.profiles where id = auth.uid();
end $$;

-- 본인 정보 수정 / 비밀번호 변경 완료 표시
create or replace function public.update_my_profile(p_name text, p_phone text, p_dept text) returns void
language sql security definer set search_path = public as $$
  update public.profiles set name = coalesce(p_name, name), phone = coalesce(p_phone, phone), dept = coalesce(p_dept, dept)
  where id = auth.uid()
$$;

create or replace function public.mark_pw_changed() returns void
language sql security definer set search_path = public as $$
  update public.profiles set must_change_pw = false where id = auth.uid()
$$;

-- 여러 기기 동기화: 내려받기 / 올리기
create or replace function public.sync_pull() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_use() then raise exception '사용 권한이 없습니다'; end if;
  return coalesce((select json_agg(json_build_object('k', k, 'v', v, 'updated_at', updated_at, 'device_id', device_id))
                   from public.user_data where user_id = auth.uid()), '[]'::json);
end $$;

create or replace function public.sync_push(p_k text, p_v jsonb, p_device text) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare ts timestamptz := now();
begin
  if not public.can_use() then raise exception '사용 권한이 없습니다'; end if;
  if p_k not like 'ams\_%' then raise exception '허용되지 않은 항목'; end if;
  if length(coalesce(p_v::text,'')) > 20000000 then raise exception '데이터가 너무 큽니다'; end if;
  insert into public.user_data (user_id, k, v, updated_at, device_id)
  values (auth.uid(), p_k, p_v, ts, coalesce(p_device,''))
  on conflict (user_id, k) do update set v = excluded.v, updated_at = ts, device_id = excluded.device_id;
  return ts;
end $$;

-- =====================================================================
--  관리자 함수 (owner·admin 만)
-- =====================================================================
create or replace function public.admin_list_users() returns table (
  id uuid, email text, name text, phone text, dept text, role text, status text, expires_at date,
  must_change_pw boolean, memo text, created_at timestamptz, approved_at timestamptz,
  last_login_at timestamptz, last_seen_at timestamptz, device_count bigint, fail_7d bigint
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '권한이 없습니다'; end if;
  return query
  select p.id, p.email, p.name, p.phone, p.dept, p.role, p.status, p.expires_at, p.must_change_pw, p.memo,
         p.created_at, p.approved_at, p.last_login_at, p.last_seen_at,
         (select count(*) from public.devices d where d.user_id = p.id),
         (select count(*) from public.login_logs l where l.email = p.email and l.event = 'login_fail'
            and l.created_at > now() - interval '7 days')
  from public.profiles p
  order by case p.status when 'pending' then 0 when 'active' then 1 else 2 end, p.created_at desc;
end $$;

-- 사용자 변경: p_action = approve / suspend / activate / expires / role / memo / force_logout / delete
create or replace function public.admin_update_user(p_user uuid, p_action text, p_value text default null) returns void
language plpgsql security definer set search_path = public as $$
declare t public.profiles; me text := public.my_role(); s public.app_settings;
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

-- 임시 비밀번호 발급 (비밀번호는 암호화되어 저장 — 원문은 이 순간 관리자 화면에만 표시)
create extension if not exists pgcrypto with schema extensions;
create or replace function public.admin_set_temp_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare t public.profiles; me text := public.my_role();
begin
  if me not in ('owner','admin') or me is null then raise exception '권한이 없습니다'; end if;
  if length(coalesce(p_password,'')) < 8 then raise exception '임시 비밀번호는 8자 이상'; end if;
  select * into t from public.profiles where id = p_user;
  if t.role = 'owner' then raise exception '제작자 비밀번호는 여기서 바꿀 수 없습니다'; end if;
  if t.role = 'admin' and me <> 'owner' then raise exception '관리자 계정은 제작자만 변경할 수 있습니다'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now()
  where id = p_user;
  update public.profiles set must_change_pw = true, force_logout_at = now() where id = p_user;
  perform public._admin_log(p_user, 'temp_password', '임시 비밀번호 발급');
end $$;

create or replace function public.admin_list_logs(p_user uuid default null, p_limit int default 300) returns setof public.login_logs
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '권한이 없습니다'; end if;
  return query select * from public.login_logs
    where p_user is null or user_id = p_user
    order by created_at desc limit least(coalesce(p_limit,300), 2000);
end $$;

create or replace function public.admin_list_devices(p_user uuid default null) returns table (
  id text, user_id uuid, email text, user_name text, name text, ua text, blocked boolean,
  first_seen timestamptz, last_seen timestamptz, last_ip text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '권한이 없습니다'; end if;
  return query select d.id, d.user_id, p.email, p.name, d.name, d.ua, d.blocked, d.first_seen, d.last_seen, d.last_ip
    from public.devices d join public.profiles p on p.id = d.user_id
    where p_user is null or d.user_id = p_user
    order by d.last_seen desc;
end $$;

create or replace function public.admin_set_device_block(p_user uuid, p_device text, p_blocked boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '권한이 없습니다'; end if;
  if (select role from public.profiles where id = p_user) = 'owner' and not public.is_owner() then
    raise exception '제작자 기기는 변경할 수 없습니다'; end if;
  update public.devices set blocked = p_blocked where user_id = p_user and id = p_device;
  perform public._admin_log(p_user, case when p_blocked then 'device_block' else 'device_unblock' end, p_device);
end $$;

create or replace function public.admin_list_admin_logs(p_limit int default 300) returns setof public.admin_logs
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '권한이 없습니다'; end if;
  return query select * from public.admin_logs order by created_at desc limit least(coalesce(p_limit,300), 2000);
end $$;

create or replace function public.admin_get_settings() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '권한이 없습니다'; end if;
  return (select row_to_json(s) from public.app_settings s where id = 1);
end $$;

create or replace function public.admin_save_settings(
  p_signup_open boolean, p_require_approval boolean, p_global_lock boolean, p_lock_message text, p_default_days int
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception '앱 전체 설정은 제작자만 바꿀 수 있습니다'; end if;
  update public.app_settings set signup_open = p_signup_open, require_approval = p_require_approval,
    global_lock = p_global_lock, lock_message = coalesce(nullif(p_lock_message,''), lock_message),
    default_days = greatest(coalesce(p_default_days,0),0), updated_at = now()
  where id = 1;
  perform public._admin_log(auth.uid(), 'settings',
    format('가입%s · 승인%s · 전체잠금%s · 기본기간%s일', p_signup_open, p_require_approval, p_global_lock, p_default_days));
end $$;

-- =====================================================================
--  실행 권한
-- =====================================================================
revoke all on function public.admin_list_users() from public, anon;
revoke all on function public.admin_update_user(uuid, text, text) from public, anon;
revoke all on function public.admin_set_temp_password(uuid, text) from public, anon;
revoke all on function public.admin_list_logs(uuid, int) from public, anon;
revoke all on function public.admin_list_devices(uuid) from public, anon;
revoke all on function public.admin_set_device_block(uuid, text, boolean) from public, anon;
revoke all on function public.admin_list_admin_logs(int) from public, anon;
revoke all on function public.admin_get_settings() from public, anon;
revoke all on function public.admin_save_settings(boolean, boolean, boolean, text, int) from public, anon;
revoke all on function public.client_checkin(text, text, text, text, timestamptz) from public, anon;
revoke all on function public.sync_pull() from public, anon;
revoke all on function public.sync_push(text, jsonb, text) from public, anon;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public._admin_log(uuid, text, text) from public, anon, authenticated;

grant execute on function public.admin_list_users() to authenticated;
grant execute on function public.admin_update_user(uuid, text, text) to authenticated;
grant execute on function public.admin_set_temp_password(uuid, text) to authenticated;
grant execute on function public.admin_list_logs(uuid, int) to authenticated;
grant execute on function public.admin_list_devices(uuid) to authenticated;
grant execute on function public.admin_set_device_block(uuid, text, boolean) to authenticated;
grant execute on function public.admin_list_admin_logs(int) to authenticated;
grant execute on function public.admin_get_settings() to authenticated;
grant execute on function public.admin_save_settings(boolean, boolean, boolean, text, int) to authenticated;
grant execute on function public.client_checkin(text, text, text, text, timestamptz) to authenticated;
grant execute on function public.public_settings() to anon, authenticated;
grant execute on function public.log_login_fail(text, text, text) to anon, authenticated;
grant execute on function public.log_logout(text, text) to authenticated;
grant execute on function public.update_my_profile(text, text, text) to authenticated;
grant execute on function public.mark_pw_changed() to authenticated;
grant execute on function public.sync_pull() to authenticated;
grant execute on function public.sync_push(text, jsonb, text) to authenticated;

grant select on public.profiles, public.devices, public.login_logs, public.admin_logs to authenticated;
grant select, insert, update, delete on public.user_data to authenticated;

-- (v2.15) 관리 범위·공유 근태는 아래 supabase_v2.15_scope.sql 내용을 이어서 실행합니다.
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

