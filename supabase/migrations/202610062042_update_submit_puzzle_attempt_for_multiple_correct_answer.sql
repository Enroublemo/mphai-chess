CREATE OR REPLACE FUNCTION public.submit_puzzle_attempt(
  p_race_id uuid,
  p_puzzle_id bigint,
  p_answer_san text
)
RETURNS TABLE (
  attempt_no integer,
  attempts_used integer,
  is_correct boolean,
  points_awarded integer,
  solution_san text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_student_id uuid;
  v_attempts_count int;
  v_puzzle_solutions text[];
  v_is_correct boolean;
  v_points int := 0;
BEGIN
  -- 1. Identify active student ID
  v_student_id := auth.uid();

  -- 2. Fetch solution array from puzzles table
  SELECT solution_san
  INTO v_puzzle_solutions
  FROM public.puzzles
  WHERE id = p_puzzle_id;

  -- 3. Check if submitted move exists anywhere in the solution_san array
  v_is_correct := (p_answer_san = ANY(v_puzzle_solutions));

  -- 4. Calculate total attempts used for this puzzle in this session
  SELECT COUNT(*) INTO v_attempts_count
  FROM public.puzzle_attempts
  WHERE race_id = p_race_id AND puzzle_id = p_puzzle_id;

  v_attempts_count := v_attempts_count + 1;

  -- 5. Calculate points based on attempt number
  IF v_is_correct THEN
    IF v_attempts_count = 1 THEN
      v_points := 3;
    ELSIF v_attempts_count = 2 THEN
      v_points := 2;
    ELSIF v_attempts_count = 3 THEN
      v_points := 1;
    END IF;
  END IF;

  -- 6. Store attempt log
  INSERT INTO public.puzzle_attempts (
    race_id,
    student_id,
    puzzle_id,
    attempt_no,
    answer_san,
    is_correct,
    points
  ) VALUES (
    p_race_id,
    v_student_id,
    p_puzzle_id,
    v_attempts_count,
    p_answer_san,
    v_is_correct,
    v_points
  );

  -- 7. Return attempt summary to client
  RETURN QUERY
  SELECT 
    v_attempts_count AS attempt_no,
    v_attempts_count AS attempts_used,
    v_is_correct AS is_correct,
    v_points AS points_awarded,
    array_to_string(v_puzzle_solutions, ' or ') AS solution_san;
END;
$$;