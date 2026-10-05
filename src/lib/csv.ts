export function downloadCsv(filename: string, headers: string[], rows: (string | number | null | undefined)[][]) {
  function escape(value: string | number | null | undefined): string {
    let s = value === null || value === undefined ? "" : String(value);
    // CSV/formula injection: Excel treats a leading = + - @ TAB CR as a formula.
    // Neutralise text cells only; real numbers (incl. negatives) are left untouched.
    if (typeof value === "string" && /^[=+\-@\t\r]/.test(s)) s = "'" + s;
    if (/[",\r\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
    return s;
  }

  // \ufeff: UTF-8 BOM so Excel (still the primary consumer per §56) opens
  // Arabic text correctly instead of guessing the wrong codepage.
  const lines = [headers.map(escape).join(","), ...rows.map((row) => row.map(escape).join(","))];
  const csv = "\ufeff" + lines.join("\r\n");

  const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename.endsWith(".csv") ? filename : `${filename}.csv`;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
}
