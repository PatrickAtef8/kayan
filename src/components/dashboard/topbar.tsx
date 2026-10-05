"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { Bell, Menu, Settings2, LogOut, BellOff } from "lucide-react";
import { GlobalSearch } from "./global-search";

export type AppNotification = {
  id: string;
  title: string;
  description: string;
  href: string;
};

export function Topbar({
  orgId,
  userEmail,
  orgName,
  roleName,
  notifications,
  onMenuClick,
}: {
  orgId: string;
  userEmail?: string;
  orgName?: string;
  roleName?: string;
  notifications: AppNotification[];
  onMenuClick: () => void;
}) {
  const initial = userEmail?.trim()?.[0]?.toUpperCase() ?? "؟";

  return (
    <header className="flex min-h-[4.5rem] items-center justify-between gap-3 border-b border-borderSoft/70 px-1 sm:px-2">
      <button onClick={onMenuClick} aria-label="فتح القائمة" className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border border-borderSoft bg-white text-charcoal/55 md:hidden">
        <Menu size={20} />
      </button>
      <GlobalSearch organizationId={orgId} />
      <div className="flex shrink-0 items-center gap-2">
        <NotificationsMenu notifications={notifications} />
        <AccountMenu initial={initial} userEmail={userEmail} orgName={orgName} roleName={roleName} />
      </div>
    </header>
  );
}

function useClickOutside(onOutside: () => void) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const close = (event: MouseEvent) => {
      if (ref.current && !ref.current.contains(event.target as Node)) onOutside();
    };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, [onOutside]);
  return ref;
}

function NotificationsMenu({ notifications }: { notifications: AppNotification[] }) {
  const [open, setOpen] = useState(false);
  const ref = useClickOutside(() => setOpen(false));
  const hasNotifications = notifications.length > 0;

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen((v) => !v)}
        aria-label="الإشعارات"
        aria-haspopup="true"
        aria-expanded={open}
        className="relative flex h-10 w-10 items-center justify-center rounded-xl border border-borderSoft bg-white text-charcoal/50 hover:text-charcoal"
      >
        <Bell size={18} />
        {hasNotifications && <span className="absolute right-2 top-2 h-1.5 w-1.5 rounded-full bg-rose" />}
      </button>
      {open && (
        <div className="absolute left-0 z-30 mt-2 w-80 overflow-hidden rounded-xl border border-borderSoft bg-white shadow-[0_18px_40px_rgba(28,28,26,0.12)]">
          <div className="border-b border-borderSoft px-4 py-3 text-xs font-medium text-charcoal/50">الإشعارات</div>
          {hasNotifications ? (
            <div className="max-h-80 overflow-y-auto">
              {notifications.map((n) => (
                <Link key={n.id} href={n.href} onClick={() => setOpen(false)} className="block border-b border-borderSoft px-4 py-3 last:border-b-0 hover:bg-paper">
                  <p className="text-sm text-charcoal">{n.title}</p>
                  <p className="mt-0.5 text-xs text-charcoal/45">{n.description}</p>
                </Link>
              ))}
            </div>
          ) : (
            <div className="flex flex-col items-center gap-2 px-4 py-8 text-center">
              <BellOff size={20} className="text-charcoal/25" />
              <p className="text-xs text-charcoal/40">لا توجد إشعارات جديدة حاليًا</p>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function AccountMenu({ initial, userEmail, orgName, roleName }: { initial: string; userEmail?: string; orgName?: string; roleName?: string }) {
  const [open, setOpen] = useState(false);
  const ref = useClickOutside(() => setOpen(false));

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen((v) => !v)}
        aria-label="حساب المستخدم"
        aria-haspopup="true"
        aria-expanded={open}
        className="flex h-10 w-10 items-center justify-center rounded-xl bg-charcoal text-sm font-semibold text-ivory transition-opacity hover:opacity-90"
        dir="ltr"
      >
        {initial}
      </button>
      {open && (
        <div className="absolute left-0 z-30 mt-2 w-64 overflow-hidden rounded-xl border border-borderSoft bg-white shadow-[0_18px_40px_rgba(28,28,26,0.12)]">
          <div className="border-b border-borderSoft px-4 py-3">
            <p className="truncate text-sm font-medium text-charcoal" dir="ltr">{userEmail ?? "—"}</p>
            <p className="mt-1 text-xs text-charcoal/45">
              {orgName ?? "مساحة العمل"}
              {roleName ? ` · ${roleName}` : ""}
            </p>
          </div>
          <Link href="/dashboard/settings" onClick={() => setOpen(false)} className="flex items-center gap-3 px-4 py-2.5 text-sm text-charcoal/70 hover:bg-paper hover:text-charcoal">
            <Settings2 size={16} />
            الإعدادات
          </Link>
          <form action="/api/auth/signout" method="post">
            <button className="flex w-full items-center gap-3 px-4 py-2.5 text-sm text-charcoal/60 hover:bg-rose/5 hover:text-rose">
              <LogOut size={16} />
              تسجيل الخروج
            </button>
          </form>
        </div>
      )}
    </div>
  );
}
