import Link from "next/link";
import type { Block, Inline } from "@/lib/legal/render";

// Renders the parsed blocks as plain React nodes (never as HTML), responsive, readable in Arabic RTL and English LTR.
function Inl({ items }: { items: Inline[] }) {
  return <>{items.map((n, i) => n.t === "bold" ? <strong key={i} className="font-semibold text-charcoal">{n.v}</strong>
    : n.t === "link" ? (n.href.startsWith("/") ? <Link key={i} href={n.href} className="text-sage underline underline-offset-4">{n.v}</Link> : <a key={i} href={n.href} className="text-sage underline underline-offset-4" rel="noopener noreferrer">{n.v}</a>)
    : <span key={i}>{n.v}</span>)}</>;
}

export function LegalArticle({ blocks }: { blocks: Block[] }) {
  return (
    <div className="space-y-4 text-[0.95rem] leading-8 text-charcoal/75">
      {blocks.map((b, i) => {
        switch (b.t) {
          case "h2": return <h2 key={i} className="pt-6 text-xl font-semibold tracking-tight text-charcoal first:pt-0"><Inl items={b.inline} /></h2>;
          case "h3": return <h3 key={i} className="pt-2 text-base font-semibold text-charcoal"><Inl items={b.inline} /></h3>;
          case "quote": return <blockquote key={i} className="border-s-4 border-sage/40 bg-sageSoft/40 px-4 py-2 text-sm"><Inl items={b.inline} /></blockquote>;
          case "ul": return <ul key={i} className="list-disc space-y-1.5 ps-6 marker:text-sage">{b.items.map((it, j) => <li key={j}><Inl items={it} /></li>)}</ul>;
          case "ol": return <ol key={i} className="list-decimal space-y-1.5 ps-6 marker:text-sage">{b.items.map((it, j) => <li key={j}><Inl items={it} /></li>)}</ol>;
          default: return <p key={i}><Inl items={b.inline} /></p>;
        }
      })}
    </div>
  );
}
