// The checkbox in /checkout: which versions did the customer see, and are they still the current ones?
import type { LegalKey } from "../../config/legal.defaults.ts";

export type LegalVersions = Record<LegalKey, number>;
export type AcceptanceInput = { terms?: unknown; privacy?: unknown; refund?: unknown } | null | undefined;
export type AcceptanceCheck = { ok: true; versions: LegalVersions } | { ok: false; reason: "missing" | "stale" | "unavailable" };

const isVersion = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v) && v >= 1;

/** `current` are the versions in the database now (null when the documents are not available). `input` is what the browser says it showed. */
export function checkAcceptance(input: AcceptanceInput, current: Partial<Record<LegalKey, unknown>> | null): AcceptanceCheck {
  if (!current || !isVersion(current.terms) || !isVersion(current.privacy) || !isVersion(current.refund)) return { ok: false, reason: "unavailable" };
  if (!input || !isVersion(input.terms) || !isVersion(input.privacy) || !isVersion(input.refund)) return { ok: false, reason: "missing" };
  if (input.terms !== current.terms || input.privacy !== current.privacy || input.refund !== current.refund) return { ok: false, reason: "stale" };
  // what is recorded is what the SERVER reads, never what the browser sent
  return { ok: true, versions: { terms: current.terms, privacy: current.privacy, refund: current.refund } };
}

export const ACCEPTANCE_MESSAGE: Record<"missing" | "stale" | "unavailable", string> = {
  missing: "يلزم الموافقة على الشروط والأحكام وسياسة الخصوصية وسياسة الإلغاء والاسترداد قبل المتابعة إلى الدفع.",
  stale: "تم تحديث الشروط أو السياسات منذ فتحت هذه الصفحة. حدّث الصفحة وراجعها ثم وافق من جديد.",
  unavailable: "الصفحات القانونية غير متاحة حاليًا، ولا يمكن بدء الدفع الآن. تواصل مع فريق كيان.",
};
