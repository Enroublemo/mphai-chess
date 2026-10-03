UPDATE public.puzzles 
SET active = true, 
    module_type = 'puzzle_race' 
WHERE active IS NOT TRUE 
   OR module_type IS DISTINCT FROM 'puzzle_race';