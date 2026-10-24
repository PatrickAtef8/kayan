// Dispatch (sales) / receiving (purchases) state of an invoice, as confirmed by the storekeeper.
const LABEL: Record<string, string> = {
  pending: "بانتظار الصرف",
  partial: "صُرف جزئيًا",
  dispatched: "تم الصرف",
  cancelled: "أُلغي بمرتجع",
};
const LABEL_PURCHASE: Record<string, string> = {
  pending: "بانتظار الاستلام",
  partial: "استُلم جزئيًا",
  received: "تم الاستلام",
  cancelled: "أُلغي بمرتجع",
};
const CLASS: Record<string, string> = {
  pending: "bg-brass/15 text-brass",
  partial: "bg-brass/15 text-brass",
  dispatched: "bg-sageSoft text-sage",
  received: "bg-sageSoft text-sage",
  cancelled: "bg-paper text-charcoal/45",
};

export function FulfilmentBadge({ status, kind, at }: { status: string | null | undefined; kind: "sales" | "purchase"; at?: string | null }) {
  if (!status) return <span className="text-charcoal/30">—</span>;
  const label = (kind === "sales" ? LABEL : LABEL_PURCHASE)[status] ?? status;
  return (
    <span title={at ? new Date(at).toLocaleString("ar-EG") : undefined} className={`whitespace-nowrap rounded-full px-2.5 py-1 text-[0.6875rem] font-medium ${CLASS[status] ?? "bg-paper text-charcoal/45"}`}>
      {label}
    </span>
  );
}
