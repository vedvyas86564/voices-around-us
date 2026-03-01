-- ============================================================
--  VOICES AROUND US — Supabase Schema
--  Paste this entire file into Supabase → SQL Editor → Run
-- ============================================================

-- ── Extensions ───────────────────────────────────────────────
create extension if not exists "uuid-ossp";

-- ── PROFILES ─────────────────────────────────────────────────
-- Created automatically when a user signs up (via trigger below)
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  emoji        text default '🌱',
  ucla_year    text,                        -- e.g. "Class of 2026"
  identity_tags text[] default '{}',
  created_at  timestamptz default now()
);
alter table public.profiles enable row level security;

create policy "Users can read all profiles"
  on public.profiles for select using (true);

create policy "Users can update own profile"
  on public.profiles for update using (auth.uid() = id);

-- Auto-create profile on signup
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, new.raw_user_meta_data->>'display_name');
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- ── STORIES ──────────────────────────────────────────────────
create table if not exists public.stories (
  id              uuid primary key default uuid_generate_v4(),
  author_id       uuid references public.profiles(id) on delete set null,
  author_name     text,                     -- denormalized for display
  is_anonymous    boolean default true,
  title           text not null,
  body            text not null,
  location_name   text not null,
  lat             float,
  lng             float,
  tags            text[] default '{}',
  emoji           text default '🌱',
  audio_url       text,                     -- optional Supabase Storage URL
  resonates       int default 0,
  reply_count     int default 0,
  created_at      timestamptz default now()
);
alter table public.stories enable row level security;

create policy "Anyone can read stories"
  on public.stories for select using (true);

create policy "Authenticated users can insert stories"
  on public.stories for insert with check (auth.uid() is not null);

create policy "Authors can update own stories"
  on public.stories for update using (auth.uid() = author_id);

create policy "Authors can delete own stories"
  on public.stories for delete using (auth.uid() = author_id);

-- Index for tag filtering
create index if not exists stories_tags_gin on public.stories using gin(tags);
create index if not exists stories_created_at on public.stories(created_at desc);


-- ── REPLIES ──────────────────────────────────────────────────
create table if not exists public.replies (
  id           uuid primary key default uuid_generate_v4(),
  story_id     uuid not null references public.stories(id) on delete cascade,
  author_id    uuid references public.profiles(id) on delete set null,
  author_name  text,                        -- denormalized for display
  is_anonymous boolean default true,
  body         text not null,
  emoji        text default '💬',
  created_at   timestamptz default now()
);
alter table public.replies enable row level security;

create policy "Anyone can read replies"
  on public.replies for select using (true);

create policy "Authenticated users can insert replies"
  on public.replies for insert with check (auth.uid() is not null);

create policy "Authors can delete own replies"
  on public.replies for delete using (auth.uid() = author_id);

create index if not exists replies_story_id on public.replies(story_id);

-- Auto-increment reply_count on stories
create or replace function public.increment_reply_count()
returns trigger language plpgsql as $$
begin
  update public.stories set reply_count = reply_count + 1 where id = new.story_id;
  return new;
end;
$$;

drop trigger if exists on_reply_inserted on public.replies;
create trigger on_reply_inserted
  after insert on public.replies
  for each row execute procedure public.increment_reply_count();

create or replace function public.decrement_reply_count()
returns trigger language plpgsql as $$
begin
  update public.stories set reply_count = greatest(reply_count - 1, 0) where id = old.story_id;
  return old;
end;
$$;

drop trigger if exists on_reply_deleted on public.replies;
create trigger on_reply_deleted
  after delete on public.replies
  for each row execute procedure public.decrement_reply_count();


-- ── RESONATES ────────────────────────────────────────────────
-- Prevents double-resonating
create table if not exists public.resonates (
  story_id   uuid not null references public.stories(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz default now(),
  primary key (story_id, user_id)
);
alter table public.resonates enable row level security;

create policy "Anyone can read resonates"
  on public.resonates for select using (true);

create policy "Authenticated users can resonate"
  on public.resonates for insert with check (auth.uid() = user_id);

create policy "Users can remove own resonate"
  on public.resonates for delete using (auth.uid() = user_id);

-- Sync resonates count
create or replace function public.sync_resonate_count()
returns trigger language plpgsql as $$
begin
  if TG_OP = 'INSERT' then
    update public.stories set resonates = resonates + 1 where id = new.story_id;
  elsif TG_OP = 'DELETE' then
    update public.stories set resonates = greatest(resonates - 1, 0) where id = old.story_id;
  end if;
  return null;
end;
$$;

drop trigger if exists on_resonate_change on public.resonates;
create trigger on_resonate_change
  after insert or delete on public.resonates
  for each row execute procedure public.sync_resonate_count();


-- ── SEED DATA ────────────────────────────────────────────────
-- These seed stories work without auth (no author_id)
insert into public.stories
  (title, body, location_name, lat, lng, tags, emoji, is_anonymous, resonates)
values
  (
    'The first time I understood everything — and still felt lost',
    E'My parents came here not speaking a word of English. I grew up translating everything — doctor appointments, tax forms, letters from school. When I got into UCLA, my mom cried for an hour.\n\nI walked into my first lecture and understood every word. But nobody in that hall knew what it took to get here. That silence felt heavier than all the languages I''d ever carried.\n\nThis library became the place I''d sit for hours. Not always studying — just existing in a space that finally felt like mine.',
    'Powell Library, UCLA', 34.0721, -118.4418,
    ARRAY['First-Gen','Belonging','Language'], '🌱', true, 14
  ),
  (
    'Found family where I least expected it',
    E'Freshman year, I didn''t know a single person on campus. I''d eat lunch alone outside this building, earbuds in, pretending to be busy.\n\nBy spring, this exact spot — this table, this overhang — became where my people gathered every single day. We''d stay here for hours, talking about everything and nothing.\n\nNow every time I walk past, I feel something I don''t have a word for yet.',
    'Ackerman Union, UCLA', 34.0710, -118.4442,
    ARRAY['Belonging','Culture'], '🌸', false, 22
  ),
  (
    'Home was a suitcase with seven countries in it',
    E'My family moved twelve times before I turned eighteen. I''ve unpacked and repacked my whole life so many times the objects stopped having meaning.\n\nI walked through Bruin Walk for the first time and felt something shift. The noise, the movement, all these strangers who were somehow choosing to be here together.\n\nI''m still looking for the thing that feels mine. But I think I''m getting closer.',
    'Bruin Walk, UCLA', 34.0712, -118.4430,
    ARRAY['Migration','Belonging'], '🧳', true, 9
  ),
  (
    'The scholarship email I almost deleted',
    E'Nobody in my family had ever attended college. When I got the application portal email, I stared at it for three days.\n\nI opened it standing right outside this building. My hands were shaking so badly I almost dropped my phone.\n\nFull scholarship. I stood there on that sidewalk and laughed until I cried, and nobody walking by knew why, and that felt exactly right.',
    'Murphy Hall, UCLA', 34.0736, -118.4412,
    ARRAY['First-Gen','Socioeconomic'], '✨', false, 31
  ),
  (
    'The call I made in two languages',
    E'Every Sunday I call my grandmother. She speaks Tagalog. I respond in English. We''ve done this for twenty years and somehow we understand each other perfectly.\n\nI realized this year that this room is where I''m most myself — the version of me that exists in both worlds at once.\n\nMy roommate doesn''t know what Tagalog sounds like. I taught her one word last week. It felt like planting something.',
    'Rieber Hall, UCLA', 34.0701, -118.4456,
    ARRAY['Language','Migration','Culture'], '📞', true, 17
  )
on conflict do nothing;
