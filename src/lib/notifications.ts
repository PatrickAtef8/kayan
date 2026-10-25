import { formatMoney } from "@/lib/money";
// Notifications (migration 0046).  Pure helpers only — no React, no Supabase — so they can be unit tested
// (`npm run test:notifications`) and shared by the server layout and the client bell.
//
// The database stores FACTS (type + payload); the wording is composed here, so money and quantities are
// formatted exactly like the rest of the app (ar-EG, 2 decimals for money).

export type NotificationType =
  | "sales_invoice_created" | "purchase_invoice_created" | "dispatch_confirmed" | "receipt_confirmed"
  | "customer_payment" | "supplier_payment" | "sales_return_created" | "purchase_return_created" | "shortage_reported"
  | "warehouse_dispatch_needed" | "warehouse_receipt_needed"
  | "rep_invoice_created" | "rep_dispatch_update" | "rep_payment" | "rep_return" | "shortage_status"
  // 0049: assignments, rep record, team, cancelled warehouse work
  | "assignment_made" | "team_activity" | "warehouse_task_cancelled"
  | "rep_customer_assigned" | "rep_customer_unassigned" | "rep_customer_updated" | "rep_invoice_assigned" | "rep_invoice_unassigned" | "rep_record_update"
  | "role_changed";

export type AppNotification = {
  id: string;
  type: NotificationType | string;
  title: string;
  href: string | null;
  payload: Record<string, unknown>;
  created_at: string;
  read_at: string | null;
  resolved_at: string | null;
};

export type NotificationIcon = "invoice" | "purchase" | "stock" | "payment" | "return" | "shortage" | "task" | "assign" | "team";

export type NotificationView = {
  icon: NotificationIcon;
  /** one short line under the title */
  summary: string | null;
  /** item rows (name + quantity text) */
  rows: { name: string; text: string }[];
  /** small grey line: who / where */
  meta: string | null;
  /** state chip: only for notifications that stand for a task */
  chip: { label: string; done: boolean } | null;
};

const TASK_TYPES = new Set(["warehouse_dispatch_needed", "warehouse_receipt_needed", "shortage_reported"]);

const REP_RECORD_TEXT: Record<string, string> = {
  linked: "تم ربط حسابك بسجل المندوب",
  unlinked: "تم فصل حسابك عن سجل المندوب",
  activated: "تم تفعيل سجل المندوب الخاص بك",
  deactivated: "تم إيقاف سجل المندوب الخاص بك",
  terms: "تم تعديل شروط العمولة أو الهدف الشهري — راجع صفحتك",
};

export const MAX_ROWS_SHOWN = 3;

export function money(n: unknown): string {
  const v = Number(n);
  if (!Number.isFinite(v)) return "";
  return `${formatMoney(v)} ج.م`;
}

export function qty(n: unknown): string {
  const v = Number(n);
  if (!Number.isFinite(v)) return "";
  return v.toLocaleString("ar-EG", { maximumFractionDigits: 3 });
}

const str = (v: unknown): string => (typeof v === "string" ? v : "");
const arr = (v: unknown): Record<string, unknown>[] => (Array.isArray(v) ? (v as Record<string, unknown>[]) : []);
const join = (parts: (string | false | null | undefined)[]) => parts.filter(Boolean).join(" · ");

function itemRows(items: Record<string, unknown>[], text: (r: Record<string, unknown>) => string) {
  return items.map((r) => ({ name: str(r.name) || str(r.product), text: text(r) }));
}

export function describeNotification(n: AppNotification): NotificationView {
  const p = n.payload ?? {};
  const task = TASK_TYPES.has(n.type);
  const chip = task ? { label: n.resolved_at ? "تم" : "بانتظار التنفيذ", done: Boolean(n.resolved_at) } : null;
  const base: NotificationView = { icon: "invoice", summary: null, rows: [], meta: null, chip };

  switch (n.type) {
    case "sales_invoice_created":
    case "rep_invoice_created": {
      const paid = Number(p.amount_paid);
      return {
        ...base, icon: "invoice",
        summary: join([str(p.customer) && `العميل ${str(p.customer)}`, p.total != null && `الإجمالي ${money(p.total)}`]),
        meta: join([str(p.by) && `بواسطة ${str(p.by)}`, paid > 0 && `مدفوع ${money(paid)}`]),
      };
    }
    case "purchase_invoice_created": {
      const paid = Number(p.amount_paid);
      return {
        ...base, icon: "purchase",
        summary: join([str(p.supplier) && `المورد ${str(p.supplier)}`, p.total != null && `الإجمالي ${money(p.total)}`]),
        meta: join([str(p.by) && `بواسطة ${str(p.by)}`, paid > 0 && `مدفوع ${money(paid)}`]),
      };
    }
    case "dispatch_confirmed":
    case "receipt_confirmed":
    case "rep_dispatch_update": {
      const verb = n.type === "receipt_confirmed" ? "استُلم" : "صُرف";
      const done = arr(p.done), left = arr(p.left);
      const rows = [
        ...itemRows(done, (r) => `${verb} ${qty(r.qty)} ${str(r.unit)}`.trim()),
        ...itemRows(left, (r) => `متبقي ${qty(r.remaining)} ${str(r.unit)}`.trim()),
      ];
      return {
        ...base, icon: "stock", rows,
        summary: str(p.status) === "partial" ? "جزئي — باقي كميات لم تكتمل" : "اكتمل بالكامل",
        meta: join([str(p.customer) && `العميل ${str(p.customer)}`, str(p.supplier) && `المورد ${str(p.supplier)}`, str(p.by) && `بواسطة ${str(p.by)}`]),
      };
    }
    case "warehouse_dispatch_needed":
    case "warehouse_receipt_needed": {
      const lines = arr(p.lines);
      const rows = itemRows(lines, (r) => {
        const ordered = Number(r.ordered), remaining = Number(r.remaining), unit = str(r.unit);
        return remaining < ordered
          ? `المطلوب ${qty(ordered)} · المتبقي ${qty(remaining)} ${unit}`.trim()
          : `المطلوب ${qty(ordered)} ${unit}`.trim();
      });
      const open = lines.filter((r) => Number(r.remaining) > 0).length;
      return {
        ...base, icon: "task", rows,
        summary: n.resolved_at ? "اكتملت المهمة" : `${qty(open)} من ${qty(lines.length)} صنف لم يكتمل`,
        meta: str(p.warehouse) ? `المخزن: ${str(p.warehouse)}` : null,
      };
    }
    case "customer_payment":
    case "rep_payment":
      return {
        ...base, icon: "payment",
        summary: join([p.amount != null && `مبلغ ${money(p.amount)}`, str(p.customer) && `من ${str(p.customer)}`]),
        meta: join([str(p.invoice_number) && `فاتورة ${str(p.invoice_number)}`, str(p.by) && `بواسطة ${str(p.by)}`]),
      };
    case "supplier_payment":
      return {
        ...base, icon: "payment",
        summary: join([p.amount != null && `مبلغ ${money(p.amount)}`, str(p.supplier) && `إلى ${str(p.supplier)}`]),
        meta: join([str(p.invoice_number) && `فاتورة ${str(p.invoice_number)}`, str(p.by) && `بواسطة ${str(p.by)}`]),
      };
    case "sales_return_created":
    case "rep_return":
      return {
        ...base, icon: "return",
        summary: join([str(p.customer) && `العميل ${str(p.customer)}`, p.total != null && `قيمة المرتجع ${money(p.total)}`]),
        meta: str(p.by) ? `بواسطة ${str(p.by)}` : null,
      };
    case "purchase_return_created":
      return {
        ...base, icon: "return",
        summary: join([str(p.supplier) && `المورد ${str(p.supplier)}`, p.total != null && `قيمة المرتجع ${money(p.total)}`]),
        meta: str(p.by) ? `بواسطة ${str(p.by)}` : null,
      };
    case "shortage_reported":
      return {
        ...base, icon: "shortage",
        summary: join([str(p.rep) && `المندوب ${str(p.rep)}`, p.needed != null && `المطلوب ${qty(p.needed)} ${str(p.unit)}`.trim(), p.available != null && `المتاح ${qty(p.available)}`]),
        meta: join([str(p.warehouse) && `المخزن: ${str(p.warehouse)}`, str(p.note)]),
      };
    case "shortage_status":
      return {
        ...base, icon: "shortage",
        summary: str(p.status) === "resolved" ? "تم توفير الكمية المطلوبة" : "جاري تجهيز الصنف",
        meta: str(p.owner_note) || null,
      };
    case "assignment_made":
      return {
        ...base, icon: "assign",
        summary: join([
          str(p.customer) && `العميل ${str(p.customer)}`,
          str(p.invoice_number) && `فاتورة ${str(p.invoice_number)}`,
          str(p.rep) ? `المندوب ${str(p.rep)}` : "بدون مندوب",
          str(p.old_rep) && `كان عند ${str(p.old_rep)}`,
        ]),
        meta: str(p.by) ? `بواسطة ${str(p.by)}` : null,
      };
    case "rep_customer_assigned":
      return { ...base, icon: "assign", summary: join([str(p.customer) && `العميل ${str(p.customer)}`, "صار ضمن عملائك"]), meta: str(p.by) ? `بواسطة ${str(p.by)}` : null };
    case "rep_customer_unassigned":
      return { ...base, icon: "assign", summary: join([str(p.customer) && `العميل ${str(p.customer)}`, "لم يعد ضمن عملائك"]), meta: str(p.by) ? `بواسطة ${str(p.by)}` : null };
    case "rep_customer_updated": {
      const fields = Array.isArray(p.fields) ? (p.fields as unknown[]).map(str).filter(Boolean) : [];
      return {
        ...base, icon: "assign",
        summary: p.deleted === true ? join([str(p.customer) && `العميل ${str(p.customer)}`, "تم حذفه"]) : join([str(p.customer) && `العميل ${str(p.customer)}`, fields.length > 0 && `تغيّر: ${fields.join("، ")}`]),
        meta: str(p.by) ? `بواسطة ${str(p.by)}` : null,
      };
    }
    case "rep_invoice_assigned":
    case "rep_invoice_unassigned":
      return {
        ...base, icon: "assign",
        summary: join([str(p.customer) && `العميل ${str(p.customer)}`, p.total != null && `الإجمالي ${money(p.total)}`]),
        meta: str(p.by) ? `بواسطة ${str(p.by)}` : null,
      };
    case "rep_record_update":
      return { ...base, icon: "assign", summary: REP_RECORD_TEXT[str(p.action)] ?? null, meta: str(p.by) ? `بواسطة ${str(p.by)}` : null };
    case "role_changed":
      return {
        ...base, icon: "team",
        summary: join([str(p.from) && `من ${str(p.from)}`, str(p.to) && `إلى ${str(p.to)}`]),
        meta: str(p.by) ? `بواسطة ${str(p.by)}` : null,
      };
    case "team_activity": {
      const from = str(p.from), to = str(p.to);
      return {
        ...base, icon: "team",
        summary: join([str(p.member) && `العضو ${str(p.member)}`, str(p.action) === "role_changed" && from && to ? `من ${from} إلى ${to}` : str(p.role) && `الدور ${str(p.role)}`]),
        meta: str(p.by) ? `بواسطة ${str(p.by)}` : null,
      };
    }
    case "warehouse_task_cancelled": {
      const rows = itemRows(arr(p.released), (r) => `أُلغي ${qty(r.qty)} ${str(r.unit)}`.trim());
      return {
        ...base, icon: "task", rows,
        summary: "لا تصرف/تستلم هذه الكميات — أُلغيت بمرتجع",
        meta: str(p.warehouse) ? `المخزن: ${str(p.warehouse)}` : null,
      };
    }
    default:
      return base;
  }
}

/** "الآن" / "منذ ٥ دقائق" / "أمس" / a date for anything older than a week */
export function timeAgo(iso: string, now: number = Date.now()): string {
  const t = new Date(iso).getTime();
  if (!Number.isFinite(t)) return "";
  const diff = Math.max(0, now - t);
  const min = Math.floor(diff / 60000);
  if (min < 1) return "الآن";
  const rtf = new Intl.RelativeTimeFormat("ar", { numeric: "auto" });
  if (min < 60) return rtf.format(-min, "minute");
  const hours = Math.floor(min / 60);
  if (hours < 24) return rtf.format(-hours, "hour");
  const days = Math.floor(hours / 24);
  if (days < 7) return rtf.format(-days, "day");
  return new Date(t).toLocaleDateString("ar-EG", { day: "numeric", month: "short", year: "numeric" });
}

// ---- list state transitions (pure, so the bell's optimistic updates are testable) ----------------------------

export function markRead(list: AppNotification[], id: string, at: string): AppNotification[] {
  return list.map((n) => (n.id === id && !n.read_at ? { ...n, read_at: at } : n));
}

export function markAllRead(list: AppNotification[], at: string): AppNotification[] {
  return list.map((n) => (n.read_at ? n : { ...n, read_at: at }));
}

/** Newest page from the server + the older rows we had already loaded. Server rows win; nothing is duplicated. */
export function mergeFirstPage(prev: AppNotification[], fresh: AppNotification[], pageSize: number): AppNotification[] {
  if (fresh.length < pageSize) return fresh;                    // the whole history fits in one page
  const oldest = fresh[fresh.length - 1].created_at;
  const ids = new Set(fresh.map((n) => n.id));
  const older = prev.filter((n) => !ids.has(n.id) && n.created_at < oldest);
  return [...fresh, ...older];
}

export function appendPage(prev: AppNotification[], next: AppNotification[]): AppNotification[] {
  const ids = new Set(prev.map((n) => n.id));
  return [...prev, ...next.filter((n) => !ids.has(n.id))];
}

export function badgeText(unread: number): string {
  return unread > 99 ? "٩٩+" : unread.toLocaleString("ar-EG");
}
