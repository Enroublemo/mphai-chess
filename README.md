# MPHAI Chess Academy — Supabase Puzzle Race v2

This replaces the localStorage prototype with Supabase Auth + PostgreSQL.

## What changed

- Student email/password accounts.
- Automatic student profile creation after signup.
- Coach/student roles.
- Central puzzle database.
- Central puzzle attempts and points.
- Every "Start New Race" creates a permanent race session.
- 3 points on first correct attempt, 2 on second, 1 on third.
- Up to 3 attempts per puzzle.
- Solution is returned by the database only after the third incorrect attempt.
- Students cannot directly insert their own results; submissions go through a Supabase RPC.
- Leaderboard is shared across devices and shows each student's best recorded race.
- Coach view shows the student leaderboard.
- The puzzle solution is not exposed by the student-facing puzzle query.

## Files

- `index.html` — complete browser app.
- `puzzles.json` — original 20-puzzle prototype data, kept for reference.
- `supabase_schema.sql` — tables, RLS, RPC functions, and the 20 puzzle seed records.
- `config.example.js` — template for the Supabase browser configuration.
- `config.js` — local placeholder configuration; replace its values.
- `make_coach.sql` — promote an existing account to the coach role.
- `README.md` — setup instructions.

## Supabase setup

1. Create a Supabase project.
2. Open **SQL Editor**.
3. Run `supabase_schema.sql` completely.
4. Copy `config.example.js` to `config.js`.
5. In Supabase, open **Project Settings → API Keys** and copy the project URL and **Publishable Key** into `config.js`.
6. Do NOT use a `service_role` or `sb_secret_...` key in `config.js`. This app runs in the browser.
7. Open the app through a local web server rather than `file://`.

Example local server:

```bash
python -m http.server 8000
```

Then open:

`http://localhost:8000/`

## Create the first coach

1. Register a normal account from the app.
2. Confirm the email if email confirmation is enabled.
3. In Supabase SQL Editor, edit `make_coach.sql` with the coach email and run it.
4. Log out and log back in. The account will show `(COACH)` and the coach dashboard will appear.

## Student accounts

Students can use **Create Student Account** on the login screen. The database trigger automatically creates a `student` profile.

For a school/academy deployment, the coach can also create the accounts in Supabase Auth and then let the trigger create their student profiles.

## Important security design

The browser uses only the Supabase Publishable Key. Row Level Security is enabled on the application tables.

Student puzzle retrieval uses a database function that returns only:
- puzzle id
- FEN
- movetext

It does not return `solution_san`.

Puzzle answers are checked by `submit_puzzle_attempt()` inside PostgreSQL. The student's browser receives only the result of the check, and the solution is returned only after the third incorrect attempt.

The raw `puzzles` table is not granted to ordinary authenticated users, so the solution column is not directly queryable by students.

## Current race behavior

Each new race is a separate `race_sessions` record. Historical attempts remain in the database.

The leaderboard currently shows each student's **best recorded race**, using:
1. highest points
2. highest correct count
3. most recent race as the final tie-breaker

This makes the system ready for future MPHAI features such as:
- weekly/monthly races
- batch/class filtering
- coach-created puzzle sets
- puzzle categories such as Mate, Tactics, Endgames, Openings
- attendance
- student progress charts
- per-puzzle success rate
- coach reports
- rankings by batch/age group
- certificates and achievement badges

## Notes

The current puzzle checker compares normalized SAN against the stored solution. `chess.js` performs the legal-move validation in the browser before the answer is submitted.

For a later hardened competition version, the move legality and complete game-state validation can also be moved server-side.

