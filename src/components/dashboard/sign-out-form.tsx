"use client";

import { useEffect, useState } from "react";
import { LogOut } from "lucide-react";
import { Spinner } from "@/components/ui/spinner";

export function SignOutForm() {
  const [pending, setPending] = useState(false);

  // Coming back via the browser's back button restores this page from cache.
  useEffect(() => {
    const reset = (event: PageTransitionEvent) => {
      if (event.persisted) setPending(false);
    };
    window.addEventListener("pageshow", reset);
    return () => window.removeEventListener("pageshow", reset);
  }, []);

  return (
    <form action="/api/auth/signout" method="post" onSubmit={() => setPending(true)}>
      <button disabled={pending} className="flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-xs text-charcoal/40 hover:bg-rose/5 hover:text-rose disabled:cursor-wait disabled:opacity-70">
        {pending ? <Spinner size={15} /> : <LogOut size={17} />}
        {pending ? "جارٍ تسجيل الخروج..." : "تسجيل الخروج"}
      </button>
    </form>
  );
}
