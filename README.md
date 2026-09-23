# Carvital

Static site (`index.html`, hosted on Vercel) with Supabase for authentication, database and invoice storage.

## Setup

1. **Create a Supabase project** at supabase.com. Choose the region **Central EU (Frankfurt)**. That keeps the data in the EU, which the privacy statement promises.
2. **Create the database:** go to SQL Editor → New query, paste `supabase/schema.sql` and click Run.
3. **Connect the frontend:** under Project Settings → API, copy the Project URL and the `anon` public key into `SUPABASE_URL` and `SUPABASE_ANON_KEY` at the top of the `<script>` in `index.html`. The anon key is meant to be public. Row Level Security makes sure every user only sees their own data. Never put the `service_role` key in the frontend.
4. **Auth settings** (Authentication → URL Configuration / Providers → Email):
   - Site URL: `https://carvital.nl` (or your Vercel URL). Add `http://localhost:5500` under Redirect URLs for local testing.
   - Leave "Confirm email" on.
   - Set the minimum password length to 8.
   - Optional: translate the e-mail templates (Authentication → Email Templates) into Dutch, and set up your own SMTP. The built-in Supabase mailer is rate-limited and only meant for testing.
5. **Company details:** fill in `COMPANY` in `index.html` with your real address, KvK number and btw-id. Dutch law requires these on your website, and they also appear in the privacy statement and terms.
6. **Data processing agreements (DPAs):** accept the DPA from Supabase (Dashboard → Organization → Legal documents) and from Vercel.

## Run locally

```bash
.venv/Scripts/python.exe -m http.server 5500
```

Then open http://localhost:5500.

## Privacy / AVG checklist (what the site does)

- Google Fonts is replaced by Bunny Fonts (EU), so no IP addresses go to Google.
- RDW lookups call the RDW directly. There are no third-party CORS proxies.
- Vercel Analytics only loads after consent. "Alleen noodzakelijk" and "Toestaan" are equally prominent, and the choice can be changed via "Cookie-instellingen" in the footer.
- Registration has a terms/16+ checkbox and a separate optional marketing opt-in. Neither is pre-ticked. The consent time and terms version are stored.
- Users can export their data themselves (JSON), and delete their account including invoices, under Profiel.
- Invoices go into a private bucket. Each user can only access their own folder.
- Location is only used when the user clicks the location button, and it is not stored.
