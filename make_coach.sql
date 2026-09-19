-- After the account has been created and its profile exists,
-- replace the email below and run this in Supabase SQL Editor.
update public.profiles
set role = 'coach'
where id = (select id from auth.users where email = 'COACH_EMAIL_HERE');
