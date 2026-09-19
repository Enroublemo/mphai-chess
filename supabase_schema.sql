-- MPHAI Chess Academy — Supabase database
-- Run this whole file in Supabase SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  role text not null default 'student' check (role in ('coach','student')),
  created_at timestamptz not null default now()
);

create table if not exists public.puzzles (
  id bigint primary key,
  fen text not null,
  solution_san text[] not null,
  movetext text,
  original_tags jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.race_sessions (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  started_at timestamptz not null default now(),
  completed_at timestamptz
);

create table if not exists public.puzzle_attempts (
  id bigint generated always as identity primary key,
  race_id uuid not null references public.race_sessions(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  puzzle_id bigint not null references public.puzzles(id) on delete cascade,
  attempt_no integer not null check (attempt_no between 1 and 3),
  answer_san text not null,
  is_correct boolean not null,
  points integer not null default 0 check (points in (0,1,2,3)),
  attempted_at timestamptz not null default now(),
  unique(race_id, puzzle_id, attempt_no)
);

create index if not exists race_sessions_student_idx on public.race_sessions(student_id, started_at desc);
create index if not exists puzzle_attempts_race_idx on public.puzzle_attempts(race_id, puzzle_id);
create index if not exists puzzle_attempts_student_idx on public.puzzle_attempts(student_id, puzzle_id);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles(id,full_name,role)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)), 'student')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.is_coach()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.profiles where id=(select auth.uid()) and role='coach');
$$;

create or replace function public.get_puzzle_race_puzzles()
returns table(id bigint, fen text, movetext text)
language sql security definer set search_path=public as $$
  select id,fen,movetext from public.puzzles where active=true order by id;
$$;

create or replace function public.start_race()
returns uuid
language plpgsql security definer set search_path=public as $$
declare v_uid uuid := (select auth.uid()); v_race uuid;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not exists(select 1 from public.profiles where id=v_uid and role='student') then
    raise exception 'Only students can start a race';
  end if;
  insert into public.race_sessions(student_id) values(v_uid) returning id into v_race;
  return v_race;
end;
$$;

create or replace function public.submit_puzzle_attempt(p_race_id uuid,p_puzzle_id bigint,p_answer_san text)
returns table(attempt_no integer,is_correct boolean,points_awarded integer,attempts_used integer,solution_san text)
language plpgsql security definer set search_path=public as $$
declare
  v_uid uuid := (select auth.uid());
  v_attempt integer; v_solution text; v_correct boolean; v_points integer;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not exists(select 1 from public.race_sessions where id=p_race_id and student_id=v_uid) then
    raise exception 'Race does not belong to this student';
  end if;
  select count(*)::integer into v_attempt from public.puzzle_attempts
    where race_id=p_race_id and puzzle_id=p_puzzle_id;
  if v_attempt >= 3 then raise exception 'Maximum 3 attempts reached'; end if;
  v_attempt := v_attempt + 1;

  select solution_san[1] into v_solution from public.puzzles where id=p_puzzle_id and active=true;
  if v_solution is null then raise exception 'Puzzle not found'; end if;

  v_correct :=
    lower(regexp_replace(replace(trim(p_answer_san),'0','O'),'[+#]$','','g'))
    =
    lower(regexp_replace(replace(trim(v_solution),'0','O'),'[+#]$','','g'));

  v_points := case when v_correct then 4-v_attempt else 0 end;

  insert into public.puzzle_attempts(race_id,student_id,puzzle_id,attempt_no,answer_san,is_correct,points)
  values(p_race_id,v_uid,p_puzzle_id,v_attempt,trim(p_answer_san),v_correct,v_points);

  return query select v_attempt,v_correct,v_points,v_attempt,
    case when (not v_correct and v_attempt=3) then v_solution else null end;
end;
$$;

create or replace function public.complete_race(p_race_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  update public.race_sessions set completed_at=coalesce(completed_at,now())
  where id=p_race_id and student_id=(select auth.uid());
end;
$$;

create or replace function public.get_leaderboard()
returns table(student_id uuid, full_name text, race_id uuid, correct integer, points integer, attempts integer, started_at timestamptz, completed_at timestamptz)
language sql security definer set search_path=public as $$
  with race_totals as (
    select r.id,r.student_id,r.started_at,r.completed_at,
           coalesce(sum(a.points),0)::integer as points,
           count(distinct a.puzzle_id) filter(where a.is_correct)::integer as correct,
           count(a.id)::integer as attempts
    from public.race_sessions r
    left join public.puzzle_attempts a on a.race_id=r.id
    group by r.id,r.student_id,r.started_at,r.completed_at
  ), best as (
    select *, row_number() over(partition by student_id order by points desc,correct desc,started_at desc) rn
    from race_totals
  )
  select b.student_id,p.full_name,b.id,b.correct,b.points,b.attempts,b.started_at,b.completed_at
  from best b join public.profiles p on p.id=b.student_id
  where p.role='student' and b.rn=1
  order by b.points desc,b.correct desc,p.full_name;
$$;

alter table public.profiles enable row level security;
alter table public.puzzles enable row level security;
alter table public.race_sessions enable row level security;
alter table public.puzzle_attempts enable row level security;

drop policy if exists "Profile access" on public.profiles;
create policy "Profile access" on public.profiles for select to authenticated
using ((select auth.uid())=id or (select public.is_coach()));

drop policy if exists "Student can update own name" on public.profiles;
create policy "Student can update own name" on public.profiles for update to authenticated
using ((select auth.uid())=id)
with check ((select auth.uid())=id and role='student');

drop policy if exists "Coach can read puzzles" on public.puzzles;
create policy "Coach can read puzzles" on public.puzzles for select to authenticated
using ((select public.is_coach()));

drop policy if exists "Own race access" on public.race_sessions;
create policy "Own race access" on public.race_sessions for select to authenticated
using ((select auth.uid())=student_id or (select public.is_coach()));

drop policy if exists "Own attempt access" on public.puzzle_attempts;
create policy "Own attempt access" on public.puzzle_attempts for select to authenticated
using ((select auth.uid())=student_id or (select public.is_coach()));

revoke execute on function public.get_puzzle_race_puzzles() from public, anon;
revoke execute on function public.get_leaderboard() from public, anon;
revoke execute on function public.start_race() from public, anon;
revoke execute on function public.submit_puzzle_attempt(uuid,bigint,text) from public, anon;
revoke execute on function public.complete_race(uuid) from public, anon;

grant usage on schema public to anon,authenticated;
grant execute on function public.get_puzzle_race_puzzles() to authenticated;
grant execute on function public.get_leaderboard() to authenticated;
grant select,update on public.profiles to authenticated;
grant select on public.race_sessions,public.puzzle_attempts to authenticated;
grant execute on function public.start_race() to authenticated;
grant execute on function public.submit_puzzle_attempt(uuid,bigint,text) to authenticated;
grant execute on function public.complete_race(uuid) to authenticated;

insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (1,'3q1rk1/5pbp/5Qp1/8/8/2B5/5PPP/6K1 w - - 0 1','{"Qxg7#"}','1.Qxg7#','{"Event": "#1 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "3q1rk1/5pbp/5Qp1/8/8/2B5/5PPP/6K1 w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (2,'2r2rk1/2q2p1p/6pQ/4P1N1/8/8/PPP5/2KR4 w - - 0 1','{"Qxh7#"}','1.Qxh7#','{"Event": "#2 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "2r2rk1/2q2p1p/6pQ/4P1N1/8/8/PPP5/2KR4 w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (3,'r2q1rk1/pp1p1p1p/5PpQ/8/4N3/8/PP3PPP/R5K1 w - - 0 1','{"Qg7#"}','1.Qg7#','{"Event": "#3 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "r2q1rk1/pp1p1p1p/5PpQ/8/4N3/8/PP3PPP/R5K1 w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (4,'6r1/7k/2p1pPp1/3p4/8/1R6/5PPP/5K2 w - - 0 1','{"Rh3#"}','1.Rh3#','{"Event": "#4 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "6r1/7k/2p1pPp1/3p4/8/1R6/5PPP/5K2 w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (5,'1r4k1/1q3p2/5Bp1/8/8/8/PP6/1K5R w - - 0 1','{"Rh8#"}','1.Rh8#','{"Event": "#5 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "1r4k1/1q3p2/5Bp1/8/8/8/PP6/1K5R w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (6,'r4rk1/5p1p/8/8/8/8/1BP5/2KR4 w - - 0 1','{"Rg1#"}','1.Rg1#','{"Event": "#6 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "r4rk1/5p1p/8/8/8/8/1BP5/2KR4 w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (7,'4r2k/4r1p1/6p1/8/2B5/8/1PP5/2KR4 w - - 0 1','{"Rh1#"}','1.Rh1#','{"Event": "#7 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "4r2k/4r1p1/6p1/8/2B5/8/1PP5/2KR4 w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (8,'8/2r1N1pk/8/8/8/2q2p2/2P5/2KR4 w - - 0 1','{"Rh1#"}','1.Rh1#','{"Event": "#8 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "8/2r1N1pk/8/8/8/2q2p2/2P5/2KR4 w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (9,'r7/4KNkp/8/8/b7/8/8/1R6 w - - 0 1','{"Rg1#"}','1.Rg1#','{"Event": "#9 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "r7/4KNkp/8/8/b7/8/8/1R6 w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (10,'2kr4/3n4/2p5/8/5B2/8/6PP/5B1K w - - 0 1','{"Ba6#"}','1.Ba6#','{"Event": "#10 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "2kr4/3n4/2p5/8/5B2/8/6PP/5B1K w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (11,'r1b1kb1r/5ppp/8/6B1/8/8/5PPP/3R3K w - - 0 1','{"Rd8#"}','1.Rd8#','{"Event": "#11 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "r1b1kb1r/5ppp/8/6B1/8/8/5PPP/3R3K w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (12,'r4rk1/p6p/1n6/6N1/3B4/3B4/6PP/7K w - - 0 1','{"Bxh7#"}','1.Bxh7#','{"Event": "#12 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "r4rk1/p6p/1n6/6N1/3B4/3B4/6PP/7K w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (13,'r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 0 1','{"Qxf7#"}','1.Qxf7#','{"Event": "#13 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (14,'rnbqkbnr/ppppp2p/5p2/6p1/3PP3/8/PPP2PPP/RNBQKBNR w KQkq - 0 1','{"Qh5#"}','1.Qh5#','{"Event": "#14 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "rnbqkbnr/ppppp2p/5p2/6p1/3PP3/8/PPP2PPP/RNBQKBNR w KQkq - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (15,'6k1/5ppp/r1p5/3b4/8/1pB5/1Pr2PPP/3RR1K1 w - - 0 1','{"Re8#"}','1.Re8#','{"Event": "#15 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "6k1/5ppp/r1p5/3b4/8/1pB5/1Pr2PPP/3RR1K1 w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (16,'rnbq1rk1/ppp1nppp/3bp3/3p3Q/3P4/3BPN2/PPP2PPP/RNB1K2R w KQ - 0 1','{"Qxh7#"}','1.Qxh7#','{"Event": "#16 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "rnbq1rk1/ppp1nppp/3bp3/3p3Q/3P4/3BPN2/PPP2PPP/RNB1K2R w KQ - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (17,'6k1/p1p2rpp/1q6/2p5/4P3/PQ6/1P4PP/3R3K w - - 0 1','{"Rd8#"}','1.Rd8#','{"Event": "#17 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "6k1/p1p2rpp/1q6/2p5/4P3/PQ6/1P4PP/3R3K w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (18,'rnb4k/p5pp/8/4N3/8/1B6/PPP5/2K4R w - - 0 1','{"Ng6#"}','1.Ng6#','{"Event": "#18 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "rnb4k/p5pp/8/4N3/8/1B6/PPP5/2K4R w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (19,'6r1/2Q2P2/5k2/5P2/5K2/8/8/8 w - - 0 1','{"fxg8=N#"}','1.fxg8=N#','{"Event": "#19 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "6r1/2Q2P2/5k2/5P2/5K2/8/8/8 w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
insert into public.puzzles(id,fen,solution_san,movetext,original_tags) values (20,'8/3pkP2/4p3/8/8/3K4/8/5R2 w - - 0 1','{"f8=Q#"}','1.f8=Q#','{"Event": "#20 Chess: 5334 Problems, Combinations, and Games by L�szl� Polg�r", "Site": "Copyright 1994 K�nemann", "Date": "1994.??.??", "Round": "-", "White": "Mate in one", "Black": "White to move", "Result": "*", "FEN": "8/3pkP2/4p3/8/8/3K4/8/5R2 w - - 0 1"}'::jsonb) on conflict (id) do update set fen=excluded.fen,solution_san=excluded.solution_san,movetext=excluded.movetext,original_tags=excluded.original_tags;
