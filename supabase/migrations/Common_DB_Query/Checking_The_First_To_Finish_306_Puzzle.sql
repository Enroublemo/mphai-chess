SELECT 
  p.username,
  p.full_name,
  pa.attempted_at AS completion_time
FROM public.profiles p
JOIN public.puzzle_attempts pa ON p.id = pa.student_id
WHERE p.role = 'student'
  AND pa.puzzle_id = 306
  AND pa.is_correct = true
ORDER BY pa.attempted_at ASC;