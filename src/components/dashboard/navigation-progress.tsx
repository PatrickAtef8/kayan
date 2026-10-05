"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { usePathname, useSearchParams } from "next/navigation";
import { endNavigation, getServerSnapshot, getSnapshot, startNavigation, subscribe } from "@/lib/navigation-state";

// Slim bar at the top of the screen that appears the instant a link is clicked
// and finishes when the new page is committed. Also marks <html> with
// data-navigating so content can be dimmed (see globals.css).
const SAFETY_TIMEOUT_MS = 12000;

export function usePendingPath() {
  return useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot).path;
}

export function NavigationProgress() {
  const state = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const locationKey = `${pathname}?${searchParams.toString()}`;

  const [progress, setProgress] = useState(0);
  const [visible, setVisible] = useState(false);
  const wasActive = useRef(false);

  // Any plain internal link click starts feedback immediately.
  useEffect(() => {
    function onClick(event: MouseEvent) {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      const anchor = (event.target as Element | null)?.closest?.("a");
      if (!anchor || !anchor.href) return;
      if (anchor.target && anchor.target !== "_self") return;
      if (anchor.hasAttribute("download")) return;
      startNavigation(anchor.href);
    }
    document.addEventListener("click", onClick, true);
    return () => document.removeEventListener("click", onClick, true);
  }, []);

  // The new page is on screen -> finish.
  useEffect(() => {
    endNavigation();
  }, [locationKey]);

  // Never leave the bar stuck (e.g. navigation cancelled or failed).
  useEffect(() => {
    if (!state.active) return;
    const timer = setTimeout(endNavigation, SAFETY_TIMEOUT_MS);
    return () => clearTimeout(timer);
  }, [state.active]);

  useEffect(() => {
    if (state.active) {
      wasActive.current = true;
      setVisible(true);
      setProgress(12);
      const interval = setInterval(() => setProgress((p) => p + (90 - p) * 0.12), 180);
      document.documentElement.dataset.navigating = "true";
      return () => clearInterval(interval);
    }
    delete document.documentElement.dataset.navigating;
    if (!wasActive.current) return;
    wasActive.current = false;
    setProgress(100);
    const timer = setTimeout(() => {
      setVisible(false);
      setProgress(0);
    }, 280);
    return () => clearTimeout(timer);
  }, [state.active]);

  return (
    <div aria-hidden="true" className="pointer-events-none fixed inset-x-0 top-0 z-[100] h-[3px]" style={{ opacity: visible ? 1 : 0, transition: "opacity 220ms ease" }}>
      <div className="h-full rounded-e-full bg-sage" style={{ width: `${progress}%`, transition: "width 200ms ease-out", boxShadow: "0 0 10px rgba(52,78,65,0.45)" }} />
    </div>
  );
}
