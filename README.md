# Carvital

Static site (`index.html`, hosted on Vercel) with Supabase for authentication, database and invoice storage.

## Setup

1. **Create a Supabase project** at supabase.com. Choose the region **Central EU (Frankfurt)**. That keeps the data in the EU, which the privacy statement promises.
2. **Create the database:** go to SQL Editor → New query, paste `supabase/schema.sql` and click Run. The script is safe to run again after it changes (for example to add the `share_links` table).
3. **Connect the frontend:** under Project Settings → API, copy the Project URL and the `anon` public key into `SUPABASE_URL` and `SUPABASE_ANON_KEY` at the top of the `<script>` in `index.html`. The anon key is meant to be public. Row Level Security makes sure every user only sees their own data. Never put the `service_role` key in the frontend.
4. **Auth settings** (Authentication → URL Configuration / Providers → Email):
   - Site URL: `https://carvital.nl` (or your Vercel URL). Add `http://localhost:5500` under Redirect URLs for local testing.
   - Leave "Confirm email" on.
   - Set the minimum password length to 8.
   - Optional: translate the e-mail templates (Authentication → Email Templates) into Dutch, and set up your own SMTP. The built-in Supabase mailer is rate-limited and only meant for testing.
5. **Company details:** fill in `COMPANY` in `index.html` with your real address, KvK number and btw-id. Dutch law requires these on your website, and they also appear in the privacy statement and terms.
6. **Data processing agreements (DPAs):** accept the DPA from Supabase (Dashboard → Organization → Legal documents) and from Vercel.

## AI invoice reading (optional)

When a user uploads an invoice under "Beurt toevoegen", the Edge Function `supabase/functions/parse-invoice` sends it to Claude. Claude returns the date, odometer reading, work done, category, garage and amount, and the form is filled in. The user checks everything before saving. The function itself stores nothing.

1. Run `supabase/schema.sql` again. It adds the `invoice_parses` table, which enforces a limit of 20 invoices per user per day.
2. Create an API key at console.anthropic.com. Accept Anthropic's DPA (Commercial Terms) there too, and set a monthly spend limit.
3. Install the Supabase CLI and link the project: `supabase login`, then `supabase link --project-ref kppcggewnkddfprutjrh`.
4. Store the key as a secret, never in the frontend: `supabase secrets set ANTHROPIC_API_KEY=sk-ant-...`
5. Deploy: `supabase functions deploy parse-invoice`

Without these steps uploading still works, but nothing is filled in automatically. The user sees a message and enters the details by hand.

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
- Sharing the history with a buyer (Overdracht) is opt-in per car. The public link (`#historie=<token>`) shows the car and records only: no name, e-mail or invoices. The owner can revoke it at any time.
