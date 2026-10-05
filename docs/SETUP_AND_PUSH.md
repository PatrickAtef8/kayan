# Kayan — after extracting: setup + private GitHub repo (SSH)

## A. Run locally
```bash
unzip kayan_latest_updated.zip && cd kayan
cp .env.example .env.local          # then fill in the 4 values (never commit this file)
npm ci
npm run dev                         # http://localhost:3000
```

## B. Apply the database changes (IMPORTANT — do this before deploying)
New migration: `supabase/migrations/0030_security_hardening.sql` (fixes C1/H1/H2/H3/H4 in docs/SECURITY_AUDIT_V2.md).
Run it once against your Supabase project:
- Dashboard → SQL Editor → paste the file → Run, **or**
- `supabase link --project-ref <ref> && supabase db push`

Verify (both should return zero rows):
```sql
select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and relkind='r' and not relrowsecurity;
select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and has_function_privilege('anon',p.oid,'execute')
  and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e');
```

## C. Supabase dashboard settings (cannot be set from code)
Authentication → turn ON "Confirm email"; set minimum password length ≥ 12 and enable leaked-password protection;
restrict Redirect URLs to your real domains; enable CAPTCHA; review rate limits.

## D. Private GitHub repo over SSH
```bash
# one-time SSH key (skip if you already have one added to GitHub)
ssh-keygen -t ed25519 -C "your-email@example.com"
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub            # GitHub → Settings → SSH and GPG keys → New SSH key
ssh -T git@github.com                # expect: "Hi PatrickAtef8! You've successfully authenticated"

# create + push (GitHub CLI route)
gh auth login                        # choose SSH when asked
gh config set git_protocol ssh
git init -b main
git add . && git status              # confirm NO .env / .env.local is listed
git commit -m "Kayan: security-hardened baseline (0030 + app patches)"
gh repo create PatrickAtef8/kayan --private --source=. --remote=origin --push

# OR without gh: create an EMPTY private repo named "kayan" on github.com, then:
git remote add origin git@github.com:PatrickAtef8/kayan.git
git push -u origin main
```
