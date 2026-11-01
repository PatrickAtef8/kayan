// Regenerates supabase/migrations/0065_legal_documents_seed.sql from src/config/legal.defaults.ts:
//   node --experimental-strip-types scripts/gen-legal-seed.mjs
// Version 1 of each document = the shipped text. Idempotent (on conflict do nothing): it never overwrites what the admin edited.
import { writeFileSync } from "node:fs";
import { LEGAL_DEFAULTS, LEGAL_KEYS } from "../src/config/legal.defaults.ts";

const tag = "$kayanlegal$";
for (const k of LEGAL_KEYS) for (const v of Object.values(LEGAL_DEFAULTS[k])) if (v.includes(tag)) throw new Error("text contains the dollar-quote tag");
const rows = LEGAL_KEYS.map((k) => {
  const d = LEGAL_DEFAULTS[k];
  return `insert into legal_documents (doc_key, version, title_ar, body_ar, title_en, body_en, change_note)\nvalues ('${k}', 1, ${tag}${d.titleAr}${tag}, ${tag}${d.bodyAr}${tag}, ${tag}${d.titleEn}${tag}, ${tag}${d.bodyEn}${tag}, 'shipped draft (needs lawyer review)')\non conflict (doc_key, version) do nothing;`;
});
writeFileSync(new URL("../supabase/migrations/0065_legal_documents_seed.sql", import.meta.url),
  `-- 0065: version 1 of the Terms, Privacy and Refund & Cancellation drafts (GENERATED from src/config/legal.defaults.ts by\n-- scripts/gen-legal-seed.mjs — edit that file and regenerate, or edit the texts in /admin/legal after deploying).\n-- Idempotent: never overwrites anything. Requires 0064.\n\n${rows.join("\n\n")}\n`);
console.log("written");
