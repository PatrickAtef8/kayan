// Turns an admin-edited legal text (a small Markdown subset) into a safe block structure. Pure: no HTML is ever produced here — the
// React component renders text nodes only, so nothing typed into the editor can inject markup or script. Links are limited to
// site-relative paths, http(s), mailto and tel.

export type LegalVars = { company_name: string; phone: string; email: string; address: string; commercial_register: string; tax_registration: string };
export type Inline = { t: "text"; v: string } | { t: "bold"; v: string } | { t: "link"; href: string; v: string };
export type Block =
  | { t: "h2" | "h3" | "p" | "quote"; inline: Inline[] }
  | { t: "ul" | "ol"; items: Inline[][] };

const REVIEW_RE = /\[\[REVIEW:\s*([\s\S]*?)\]\]/g;

/** Replaces {{placeholders}}; a value that is not filled in yet shows as "—" so a page never shows a raw token. */
export function fillPlaceholders(md: string, vars: Partial<LegalVars>): string {
  return md.replace(/\{\{\s*([a-z_]+)\s*\}\}/g, (_m, k: string) => {
    const v = (vars as Record<string, string | undefined>)[k];
    return v && v.trim() ? v.trim() : "—";
  });
}

/** The lawyer-review markers: removed from anything the public sees… */
export function stripReviewNotes(md: string): string {
  return md.replace(REVIEW_RE, "").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
}

/** …and listed for the admin. */
export function extractReviewNotes(md: string): string[] {
  const out: string[] = [];
  for (const m of md.matchAll(REVIEW_RE)) out.push(m[1].trim());
  return out;
}

export function safeHref(h: string): string | null {
  const s = h.trim();
  if (/^\/(?!\/)/.test(s)) return s;                       // site-relative (not protocol-relative)
  if (/^https?:\/\/[^\s]+$/i.test(s)) return s;
  if (/^mailto:[^\s]+$/i.test(s)) return s;
  if (/^tel:[+0-9()\-\s]+$/i.test(s)) return s;
  return null;
}

export function parseInline(src: string): Inline[] {
  const out: Inline[] = [];
  const re = /\*\*([^*]+)\*\*|\[([^\]]+)\]\(([^)\s]+)\)/g;
  let last = 0;
  for (const m of src.matchAll(re)) {
    const i = m.index ?? 0;
    if (i > last) out.push({ t: "text", v: src.slice(last, i) });
    if (m[1] !== undefined) out.push({ t: "bold", v: m[1] });
    else {
      const href = safeHref(m[3]);
      out.push(href ? { t: "link", href, v: m[2] } : { t: "text", v: m[2] });   // an unsafe link degrades to its text
    }
    last = i + m[0].length;
  }
  if (last < src.length) out.push({ t: "text", v: src.slice(last) });
  return out;
}

export function parseMarkdown(md: string): Block[] {
  const blocks: Block[] = [];
  const lines = md.replace(/\r\n?/g, "\n").split("\n");
  let para: string[] = [];
  let list: { kind: "ul" | "ol"; items: Inline[][] } | null = null;
  const flushPara = () => { if (para.length) { blocks.push({ t: "p", inline: parseInline(para.join(" ")) }); para = []; } };
  const flushList = () => { if (list) { blocks.push({ t: list.kind, items: list.items }); list = null; } };
  for (const raw of lines) {
    const line = raw.trim();
    if (!line) { flushPara(); flushList(); continue; }
    let m: RegExpMatchArray | null;
    if ((m = line.match(/^###\s+(.+)$/))) { flushPara(); flushList(); blocks.push({ t: "h3", inline: parseInline(m[1]) }); }
    else if ((m = line.match(/^##\s+(.+)$/))) { flushPara(); flushList(); blocks.push({ t: "h2", inline: parseInline(m[1]) }); }
    else if ((m = line.match(/^>\s?(.*)$/))) { flushPara(); flushList(); blocks.push({ t: "quote", inline: parseInline(m[1]) }); }
    else if ((m = line.match(/^[-*]\s+(.+)$/))) { flushPara(); if (!list || list.kind !== "ul") { flushList(); list = { kind: "ul", items: [] }; } list.items.push(parseInline(m[1])); }
    else if ((m = line.match(/^\d+[.)]\s+(.+)$/))) { flushPara(); if (!list || list.kind !== "ol") { flushList(); list = { kind: "ol", items: [] }; } list.items.push(parseInline(m[1])); }
    else { flushList(); para.push(line); }
  }
  flushPara(); flushList();
  return blocks;
}

/** Everything the public page needs from one stored text. */
export function renderLegal(md: string, vars: Partial<LegalVars>): Block[] {
  return parseMarkdown(stripReviewNotes(fillPlaceholders(md, vars)));
}
