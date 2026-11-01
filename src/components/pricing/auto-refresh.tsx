"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";

// Re-reads the server page every few seconds while a payment is still being confirmed, then gives up politely
// (the webhook keeps working whether or not this page is open).
export function AutoRefresh({ everyMs = 4000, maxTries = 30 }: { everyMs?: number; maxTries?: number }) {
  const router = useRouter();
  const tries = useRef(0);
  useEffect(() => {
    const id = setInterval(() => {
      if (++tries.current > maxTries) { clearInterval(id); return; }
      router.refresh();
    }, everyMs);
    return () => clearInterval(id);
  }, [router, everyMs, maxTries]);
  return null;
}
