// Verstuurt APK-herinneringen: 30 dagen voor de vervaldatum, één mail per auto per APK-datum.
// Wordt elke ochtend aangeroepen door pg_cron (zie README). Testen zonder te mailen: ?dry=1
//
// Deploy:   supabase functions deploy send-reminders --no-verify-jwt
// Secrets:  supabase secrets set BREVO_API_KEY=... CRON_SECRET=...
import { createClient } from "npm:@supabase/supabase-js@2.119.2";

const DAYS = 30;
const SITE = "https://carvital.nl";
const SENDER = { name: "Carvital", email: "noreply@carvital.nl" };

type Due = {
  user_id: string; email: string; name: string; car_id: string;
  kenteken: string; merk: string | null; model: string | null; apk_vervaldatum: string;
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

function fmtKent(k: string) {
  const parts = k.match(/[A-Z]+|[0-9]+/g) ?? [k];
  return parts.length >= 3 ? parts.join("-") : (k.match(/.{1,2}/g) ?? [k]).join("-");
}

const fmtDate = (iso: string) =>
  new Date(iso + "T12:00:00Z").toLocaleDateString("nl-NL", { day: "numeric", month: "long", year: "numeric" });

const daysUntil = (iso: string) => Math.round((Date.parse(iso + "T00:00:00Z") - Date.parse(new Date().toISOString().slice(0, 10) + "T00:00:00Z")) / 864e5);

// Actuele APK-datum bij de RDW: wie al gekeurd is, krijgt geen onterechte herinnering
async function rdwApkDate(kenteken: string): Promise<string | null> {
  try {
    const res = await fetch(`https://opendata.rdw.nl/resource/m9d7-ebf2.json?kenteken=${encodeURIComponent(kenteken)}`);
    const [v] = res.ok ? await res.json() : [];
    const d: string | undefined = v?.vervaldatum_apk;
    return d && d.length === 8 ? `${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6, 8)}` : null;
  } catch {
    return null;
  }
}

function mail(r: Due, days: number) {
  const auto = [r.merk, r.model].filter(Boolean).join(" ") || "je auto";
  const first = (r.name || "").split(" ")[0];
  const subject = `De APK van je ${auto} verloopt over ${days} dagen`;
  const html = `<!doctype html><html lang="nl"><body style="margin:0;padding:0;background:#F4F0EC;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F4F0EC;padding:32px 12px;"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#FFFFFF;border-radius:6px;overflow:hidden;font-family:Arial,Helvetica,sans-serif;">
<tr><td style="background:#1A1512;padding:22px 32px;"><span style="font-size:20px;font-weight:bold;letter-spacing:3px;color:#D2C4B0;">CARVITAL</span></td></tr>
<tr><td style="padding:32px;">
<h1 style="margin:0 0 14px;font-size:22px;line-height:1.3;color:#1A1512;">${first ? `Hoi ${esc(first)}, de` : "De"} APK van je ${esc(auto)} verloopt over ${days} dagen</h1>
<p style="margin:0 0 18px;font-size:15px;line-height:1.6;color:#6B5D50;">De APK van <strong style="color:#1A1512;">${esc(fmtKent(r.kenteken))}</strong> is geldig tot <strong style="color:#1A1512;">${esc(fmtDate(r.apk_vervaldatum))}</strong>. Plan op tijd een keuring; na die datum mag je er niet meer mee de weg op.</p>
<table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#1A1512;border-radius:3px;">
<a href="${SITE}/" style="display:inline-block;padding:14px 26px;font-size:14px;font-weight:bold;letter-spacing:1px;color:#F2ECE7;text-decoration:none;">APK-GARAGE ZOEKEN</a>
</td></tr></table>
<p style="margin:22px 0 0;font-size:13px;line-height:1.6;color:#9A8D80;">Log in en kijk bij Garages: garages met "APK-erkend" mogen de keuring doen.</p>
</td></tr>
<tr><td style="padding:20px 32px;border-top:1px solid #E2D9CE;font-size:12px;line-height:1.6;color:#9A8D80;">
Je krijgt deze mail omdat APK-herinneringen aan staan in je Carvital-account. Uitzetten kan in de app onder Profiel → Voorkeuren.
</td></tr></table></td></tr></table></body></html>`;
  return { subject, html };
}

Deno.serve(async (req) => {
  // Alleen de dagelijkse cron (met het geheime token) mag dit starten
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) return json({ error: "Niet toegestaan" }, 401);
  const dry = new URL(req.url).searchParams.get("dry") === "1";

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data, error } = await sb.rpc("due_apk_reminders", { p_days: DAYS });
  if (error) return json({ error: error.message }, 500);

  const brevoKey = Deno.env.get("BREVO_API_KEY");
  if (!dry && !brevoKey) return json({ error: "BREVO_API_KEY ontbreekt" }, 500);

  const result = { due: (data as Due[]).length, sent: 0, skipped_renewed: 0, failed: 0, dry, preview: [] as string[] };
  for (const r of data as Due[]) {
    // APK-datum bij de RDW nagaan; is hij vernieuwd, dan de auto bijwerken en overslaan
    const current = await rdwApkDate(r.kenteken);
    if (current && current !== r.apk_vervaldatum) {
      if (!dry) await sb.from("cars").update({ apk_vervaldatum: current }).eq("id", r.car_id);
      if (daysUntil(current) > DAYS || daysUntil(current) < 0) { result.skipped_renewed++; continue; }
      r.apk_vervaldatum = current;
    }
    const days = daysUntil(r.apk_vervaldatum);
    const { subject, html } = mail(r, days);
    if (dry) { result.preview.push(`${r.kenteken}: ${subject}`); continue; }

    const res = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: { "api-key": brevoKey!, "Content-Type": "application/json", accept: "application/json" },
      body: JSON.stringify({ sender: SENDER, to: [{ email: r.email, name: r.name || undefined }], subject, htmlContent: html, tags: ["apk-reminder"] }),
    });
    if (!res.ok) { result.failed++; console.error("Brevo", res.status, await res.text()); continue; }
    await sb.from("apk_reminders_sent").insert({ car_id: r.car_id, apk_date: r.apk_vervaldatum, user_id: r.user_id });
    result.sent++;
  }
  // geen e-mailadressen of kentekens in het antwoord, behalve in een testrun
  return json(result);
});
