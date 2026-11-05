// "Type the company name to confirm" — the comparison, pure so it can be tested. Exact means exact: same letters, same case.
// Only two things are forgiven: invisible differences in how the same Arabic/Latin text is encoded (Unicode NFC) and spaces
// around the whole value (a paste often carries them). Nothing inside the name is normalised, so «شركة النور» never matches «شركة  النور».
export function namesMatch(typed: unknown, actual: unknown): boolean {
  if (typeof typed !== "string" || typeof actual !== "string") return false;
  const a = actual.normalize("NFC").trim();
  if (a.length === 0) return false;
  return typed.normalize("NFC").trim() === a;
}
