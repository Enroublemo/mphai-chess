-- Run this in your Supabase SQL Editor so the user's progress table tracks their last visited category and subcategory.
ALTER TABLE user_progress 
ADD COLUMN IF NOT EXISTS last_category TEXT DEFAULT 'Puzzle',
ADD COLUMN IF NOT EXISTS last_subcategory TEXT DEFAULT 'puzzle_race';

