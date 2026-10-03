-- 1. Create the user_progress table if it doesn't exist
CREATE TABLE IF NOT EXISTS user_progress (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    last_category TEXT DEFAULT 'Puzzle',
    last_subcategory TEXT DEFAULT 'puzzle_race',
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Add columns if the table was created previously without them
ALTER TABLE user_progress 
ADD COLUMN IF NOT EXISTS last_category TEXT DEFAULT 'Puzzle',
ADD COLUMN IF NOT EXISTS last_subcategory TEXT DEFAULT 'puzzle_race',
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- 3. Enable Row Level Security (RLS)
ALTER TABLE user_progress ENABLE ROW LEVEL SECURITY;

-- 4. Create RLS Policies so students can read and write their own data
DROP POLICY IF EXISTS "Users can view own progress" ON user_progress;
CREATE POLICY "Users can view own progress" 
ON user_progress FOR SELECT 
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert/update own progress" ON user_progress;
CREATE POLICY "Users can insert/update own progress" 
ON user_progress FOR ALL 
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);