"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { Bell, BellOff, CheckCheck, ClipboardCheck, FileText, Loader2, PackageCheck, PackageX, ShoppingBag, Undo2, UserCheck, Users, Wallet } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import {
  appendPage, badgeText, describeNotification, markAllRead, markRead, mergeFirstPage, timeAgo, MAX_ROWS_SHOWN,
  type AppNotification, type NotificationIcon,
} from "@/lib/notifications";

const PAGE = 20;

const ICONS: Record<NotificationIcon, typeof Bell> = {
  invoice: FileText, purchase: ShoppingBag, stock: PackageCheck, payment: Wallet, return: Undo2, shortage: PackageX, task: ClipboardCheck, assign: UserCheck, team: Users,
};

type Filter = "all" | "unread";

// The bell.  The server renders the first page (so there is no empty flash); from then on the list follows
// the database through Supabase Realtime.  Anything that could have been missed — a dropped connection, a
// sleeping tab — is covered by a refetch on (re)subscribe, on focus/visibility and on reconnect, and by a
// slow poll that only runs while the live channel is down.  Read state lives in the database (per person).
export function NotificationsMenu({ orgId, userId, initialItems, initialUnread }: {
  orgId: string; userId: string; initialItems: AppNotification[]; initialUnread: number;
}) {
  const [supabase] = useState(() => createClient());
  const [open, setOpen] = useState(false);
  const [items, setItems] = useState<AppNotification[]>(initialItems);
  const [unread, setUnread] = useState(initialUnread);
  const [hasMore, setHasMore] = useState(initialItems.length >= PAGE);
  const [filter, setFilter] = useState<Filter>("all");
  const [busy, setBusy] = useState<"more" | "all" | null>(null);
  const [failed, setFailed] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const liveRef = useRef(false);
  const itemsRef = useRef(items);
  useEffect(() => { itemsRef.current = items; }, [items]);

  const refresh = useCallback(async () => {
    // Deliver anything whose creation failed earlier (0047). Cheap when nothing is pending; errors are not fatal.
    await supabase.rpc("process_notification_retries", { org_id: orgId });
    const [list, count] = await Promise.all([
      supabase.rpc("list_my_notifications", { org_id: orgId, p_filter: "all", p_limit: PAGE }),
      supabase.rpc("my_unread_notification_count", { org_id: orgId }),
    ]);
    if (list.error || count.error) { setFailed(true); return; }
    setFailed(false);
    const fresh = (list.data as AppNotification[] | null) ?? [];
    setItems((prev) => mergeFirstPage(prev, fresh, PAGE));
    setUnread(Number(count.data) || 0);
    if (fresh.length < PAGE) setHasMore(false);
  }, [supabase, orgId]);

  // live updates
  useEffect(() => {
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const later = () => { clearTimeout(timer); timer = setTimeout(() => { if (!cancelled) void refresh(); }, 200); };

    const { data: auth } = supabase.auth.onAuthStateChange((event, session) => {
      if (session && (event === "TOKEN_REFRESHED" || event === "SIGNED_IN")) supabase.realtime.setAuth(session.access_token);
    });

    const channel = supabase.channel(`notifications:${userId}`);
    void (async () => {
      const { data } = await supabase.auth.getSession();
      if (cancelled) return;
      if (data.session) supabase.realtime.setAuth(data.session.access_token);   // Realtime must evaluate RLS as THIS user
      channel
        .on("postgres_changes", { event: "*", schema: "public", table: "notifications", filter: `recipient_user_id=eq.${userId}` }, later)
        .subscribe((status) => {
          liveRef.current = status === "SUBSCRIBED";
          if (status === "SUBSCRIBED" && !cancelled) void refresh();             // catch up on anything missed while offline
        });
    })();

    const wake = () => { if (document.visibilityState === "visible") void refresh(); };
    window.addEventListener("focus", wake);
    window.addEventListener("online", wake);
    document.addEventListener("visibilitychange", wake);
    const poll = setInterval(() => { if (!liveRef.current && document.visibilityState === "visible") void refresh(); }, 60_000);

    return () => {
      cancelled = true;
      clearTimeout(timer);
      clearInterval(poll);
      window.removeEventListener("focus", wake);
      window.removeEventListener("online", wake);
      document.removeEventListener("visibilitychange", wake);
      auth.subscription.unsubscribe();
      void supabase.removeChannel(channel);
    };
  }, [supabase, userId, refresh]);

  // close on outside click / Escape
  useEffect(() => {
    if (!open) return;
    const outside = (e: MouseEvent) => { if (rootRef.current && !rootRef.current.contains(e.target as Node)) setOpen(false); };
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", outside);
    document.addEventListener("keydown", esc);
    return () => { document.removeEventListener("mousedown", outside); document.removeEventListener("keydown", esc); };
  }, [open]);

  async function openItem(n: AppNotification) {
    setOpen(false);
    if (n.read_at) return;
    const at = new Date().toISOString();
    setItems((prev) => markRead(prev, n.id, at));
    setUnread((u) => Math.max(0, u - 1));
    const { data, error } = await supabase.rpc("mark_notification_read", { org_id: orgId, p_id: n.id });
    if (error) void refresh();
    else if (typeof data === "number") setUnread(data);
  }

  async function readAll() {
    if (unread === 0 || busy) return;
    setBusy("all");
    const at = new Date().toISOString();
    setItems((prev) => markAllRead(prev, at));
    setUnread(0);
    const { data, error } = await supabase.rpc("mark_all_notifications_read", { org_id: orgId });
    if (error) void refresh();
    else if (typeof data === "number") setUnread(data);
    setBusy(null);
  }

  async function loadMore() {
    const last = itemsRef.current[itemsRef.current.length - 1];
    if (!last || busy) return;
    setBusy("more");
    const { data, error } = await supabase.rpc("list_my_notifications", { org_id: orgId, p_filter: "all", p_limit: PAGE, p_before: last.created_at });
    if (!error) {
      const next = (data as AppNotification[] | null) ?? [];
      setItems((prev) => appendPage(prev, next));
      if (next.length < PAGE) setHasMore(false);
    }
    setBusy(null);
  }

  const shown = filter === "unread" ? items.filter((n) => !n.read_at) : items;

  return (
    <div ref={rootRef} className="relative">
      <button
        onClick={() => setOpen((v) => !v)}
        aria-label={unread > 0 ? `الإشعارات — ${unread} غير مقروءة` : "الإشعارات"}
        aria-haspopup="true"
        aria-expanded={open}
        className="relative flex h-10 w-10 items-center justify-center rounded-xl border border-borderSoft bg-white text-charcoal/50 transition-colors hover:text-charcoal"
      >
        <Bell size={18} />
        {unread > 0 && (
          <span className="absolute -right-1.5 -top-1.5 flex h-[1.125rem] min-w-[1.125rem] items-center justify-center rounded-full bg-rose px-1 text-[0.625rem] font-semibold leading-none text-white ring-2 ring-white">
            {badgeText(unread)}
          </span>
        )}
      </button>
      <span className="sr-only" aria-live="polite">{unread > 0 ? `${unread} إشعار غير مقروء` : ""}</span>

      {open && (
        <div className="fixed inset-x-3 top-[4.75rem] z-30 overflow-hidden rounded-xl border border-borderSoft bg-white shadow-[0_18px_40px_rgba(28,28,26,0.12)] sm:absolute sm:inset-x-auto sm:left-0 sm:top-auto sm:mt-2 sm:w-[25rem]">
          <div className="flex items-center justify-between gap-2 border-b border-borderSoft px-4 py-3">
            <p className="text-sm font-semibold text-charcoal">الإشعارات</p>
            <button
              onClick={readAll}
              disabled={unread === 0 || busy === "all"}
              className="flex items-center gap-1.5 rounded-lg px-2 py-1 text-xs font-medium text-sage transition-colors hover:bg-sageSoft disabled:cursor-default disabled:text-charcoal/25 disabled:hover:bg-transparent"
            >
              <CheckCheck size={14} />
              تحديد الكل كمقروء
            </button>
          </div>

          <div className="flex gap-1 border-b border-borderSoft px-3 py-2" role="tablist">
            {([["all", "الكل"], ["unread", unread > 0 ? `غير المقروءة (${unread.toLocaleString("ar-EG")})` : "غير المقروءة"]] as const).map(([key, label]) => (
              <button key={key} role="tab" aria-selected={filter === key} onClick={() => setFilter(key)}
                className={`rounded-lg px-2.5 py-1.5 text-xs font-medium transition-colors ${filter === key ? "bg-sageSoft text-sage" : "text-charcoal/45 hover:bg-paper"}`}>
                {label}
              </button>
            ))}
          </div>

          {failed && <p className="border-b border-borderSoft bg-rose/5 px-4 py-2 text-xs text-rose">تعذّر تحديث الإشعارات — سنعيد المحاولة تلقائيًا.</p>}

          {shown.length === 0 ? (
            <div className="flex flex-col items-center gap-2 px-4 py-10 text-center">
              <BellOff size={20} className="text-charcoal/25" />
              <p className="text-xs text-charcoal/40">{filter === "unread" ? "لا توجد إشعارات غير مقروءة" : "لا توجد إشعارات بعد"}</p>
            </div>
          ) : (
            <ul className="max-h-[min(26rem,70vh)] divide-y divide-borderSoft overflow-y-auto">
              {shown.map((n) => <Row key={n.id} n={n} onOpen={openItem} />)}
              {hasMore && filter === "all" && (
                <li>
                  <button onClick={loadMore} disabled={busy === "more"} className="flex w-full items-center justify-center gap-2 px-4 py-3 text-xs font-medium text-sage hover:bg-paper disabled:text-charcoal/30">
                    {busy === "more" && <Loader2 size={14} className="animate-spin" />}
                    عرض إشعارات أقدم
                  </button>
                </li>
              )}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}

function Row({ n, onOpen }: { n: AppNotification; onOpen: (n: AppNotification) => void }) {
  const v = describeNotification(n);
  const Icon = ICONS[v.icon];
  const isUnread = !n.read_at;
  const body = (
    <div className={`flex gap-3 px-4 py-3 transition-colors hover:bg-paper ${isUnread ? "bg-sageSoft/40" : ""}`}>
      <span className={`mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-lg ${isUnread ? "bg-sageSoft text-sage" : "bg-paper text-charcoal/35"}`}>
        <Icon size={16} />
      </span>
      <div className="min-w-0 flex-1">
        <div className="flex items-start justify-between gap-2">
          <p className={`text-sm leading-snug ${isUnread ? "font-semibold text-charcoal" : "text-charcoal/70"}`}>{n.title}</p>
          {isUnread && <span aria-label="غير مقروء" className="mt-1.5 h-2 w-2 shrink-0 rounded-full bg-rose" />}
        </div>
        {v.summary && <p className="mt-0.5 text-xs text-charcoal/55">{v.summary}</p>}
        {v.rows.length > 0 && (
          <ul className="mt-1.5 space-y-0.5 rounded-lg bg-paper px-2.5 py-1.5">
            {v.rows.slice(0, MAX_ROWS_SHOWN).map((r, i) => (
              <li key={i} className="flex items-baseline justify-between gap-3 text-xs">
                <span className="truncate text-charcoal/70">{r.name}</span>
                <span className="shrink-0 text-charcoal/50">{r.text}</span>
              </li>
            ))}
            {v.rows.length > MAX_ROWS_SHOWN && <li className="text-[0.6875rem] text-charcoal/40">و {(v.rows.length - MAX_ROWS_SHOWN).toLocaleString("ar-EG")} بنود أخرى</li>}
          </ul>
        )}
        <div className="mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-[0.6875rem] text-charcoal/40">
          <span>{timeAgo(n.created_at)}</span>
          {v.meta && <span className="truncate">· {v.meta}</span>}
          {v.chip && (
            <span className={`rounded-full px-2 py-0.5 text-[0.625rem] font-medium ${v.chip.done ? "bg-sageSoft text-sage" : "bg-rose/10 text-rose"}`}>{v.chip.label}</span>
          )}
        </div>
      </div>
    </div>
  );
  return (
    <li>
      {n.href ? (
        <Link href={n.href} onClick={() => onOpen(n)} className="block">{body}</Link>
      ) : (
        <button onClick={() => onOpen(n)} className="block w-full text-start">{body}</button>
      )}
    </li>
  );
}
