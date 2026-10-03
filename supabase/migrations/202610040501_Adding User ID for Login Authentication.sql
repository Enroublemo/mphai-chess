-- 1. Ensure profiles table has a username/userID column
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS username text UNIQUE;

-- 2. Create RPC function to look up email from either email or User ID
CREATE OR REPLACE FUNCTION get_user_email(p_identifier text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_email text;
BEGIN
  -- If input is already an email address, return it as-is
  IF p_identifier LIKE '%@%' THEN
    RETURN p_identifier;
  END IF;

  -- Search for matching username or profile ID
  SELECT u.email INTO v_email
  FROM public.profiles p
  JOIN auth.users u ON u.id = p.id
  WHERE LOWER(p.username) = LOWER(p_identifier)
     OR p.id::text = p_identifier;

  RETURN v_email;
END;
$$;