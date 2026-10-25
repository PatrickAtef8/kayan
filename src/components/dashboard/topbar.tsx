"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { Menu, Settings2, LogOut, Globe } from "lucide-react";
import { GlobalSearch } from "./global-search";
import { NotificationsMenu } from "./notifications-menu";
import type { AppNotification } from "@/lib/notifications";

export function Topbar({
  orgId,
  userId,
  userEmail,
  orgName,
  roleName,
  initialNotifications,
  initialUnread,
  onMenuClick,
}: {
  orgId: string;
  userId: string;
  userEmail?: string;
  orgName?: string;
  roleName?: string;
  initialNotifications: AppNotification[];
  initialUnread: number;
  onMenuClick: () => void;
}) {
  const initial = userEmail?.trim()?.[0]?.toUpperCase() ?? "؟";

  return (
    <header className="flex min-h-[4rem] items-center gap-2 border-b border-borderSoft/70 px-0 sm:min-h-[4.5rem] sm:gap-3 sm:px-2">
      <button onClick={onMenuClick} aria-label="فتح القائمة" className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border border-borderSoft bg-white text-charcoal/55 lg:hidden">
        <Menu size={20} />
      </button>
      <GlobalSearch organizationId={orgId} />
      <div className="mr-auto flex shrink-0 items-center gap-2">
        <NotificationsMenu orgId={orgId} userId={userId} initialItems={initialNotifications} initialUnread={initialUnread} />
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
        <div className="absolute left-0 z-30 mt-2 w-64 max-w-[calc(100vw-1.75rem)] overflow-hidden rounded-xl border border-borderSoft bg-white shadow-[0_18px_40px_rgba(28,28,26,0.12)]">
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
          <Link href="/" onClick={() => setOpen(false)} className="flex items-center gap-3 px-4 py-2.5 text-sm text-charcoal/70 hover:bg-paper hover:text-charcoal">
            <Globe size={16} />
            الصفحة التعريفية
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
