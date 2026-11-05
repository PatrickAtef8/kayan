# Supabase Authentication settings (dashboard — not settable from code)

| Setting | Value | Why |
|---|---|---|
| Confirm email | **ON** | Super Admin email matching and invitations trust a confirmed address. |
| Minimum password length | **8** | This is what the app enforces (`MIN_PASSWORD_LENGTH`, `src/lib/password-strength.ts`). Lower in Supabase would weaken it; higher would reject passwords the form accepts. |
| Leaked password protection | ON if your plan offers it | Extra protection, no code needed. |
| **CAPTCHA protection** | **OFF** | The sign-up, sign-in and reset forms do **not** send a `captchaToken`. Turning CAPTCHA on today makes every sign-up and login fail. Enable it only after the forms are changed to obtain a token (hCaptcha/Turnstile) and pass it in `options.captchaToken`. In the meantime: app-level rate limits + Supabase Auth rate limits. |
| Site URL | your production address (`NEXT_PUBLIC_SITE_URL`) | Used by the `{{ .SiteURL }}` links in the auth email templates. |
| Redirect URLs | your production domain(s) (and the Vercel preview pattern if you use previews) | Open-redirect protection. |
| Custom SMTP | Resend — see `docs/EMAIL.md` | Branded auth emails, no built-in sending limits. |
| JWT signing keys | check — see `docs/PERFORMANCE.md` | Faster auth on every request when asymmetric. |
| Point-in-time recovery / backups | see `docs/BACKUP_AND_RECOVERY.md` | Required before deleting companies is safe. |
