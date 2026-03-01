-- Run this in Supabase → SQL Editor to add the missing author_name columns
-- Fixes: "Could not find the 'author_name' column of 'stories' in the schema cache"

alter table public.stories add column if not exists author_name text;
alter table public.replies add column if not exists author_name text;
