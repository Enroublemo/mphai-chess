-- 1. Ensure the profiles table includes username
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS username TEXT UNIQUE;

-- 2. Stored Procedure to lookup email by User ID / Username
CREATE OR REPLACE FUNCTION public.get_user_email(p_identifier TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_email TEXT;
BEGIN
  SELECT email INTO v_email
  FROM auth.users u
  JOIN public.profiles p ON u.id = p.id
  WHERE LOWER(p.username) = LOWER(p_identifier)
     OR LOWER(p.full_name) = LOWER(p_identifier)
  LIMIT 1;
  
  RETURN v_email;
END;
$$;