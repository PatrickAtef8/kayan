"use client";

import { useEffect } from "react";

export function SmoothScroll({ children }: { children: React.ReactNode }) {
  useEffect(() => {
    // Smooth scrolling is an enhancement, so the library is fetched after the
    // page is interactive instead of blocking the landing page's first load.
    let cancelled = false;
    let frame = 0;
    let destroy: (() => void) | undefined;

    import("lenis").then(({ default: Lenis }) => {
      if (cancelled) return;
      const lenis = new Lenis({
        autoRaf: false,
        lerp: 0.08,
        smoothWheel: true,
      });
      const raf = (time: number) => {
        lenis.raf(time);
        frame = window.requestAnimationFrame(raf);
      };
      frame = window.requestAnimationFrame(raf);
      destroy = () => lenis.destroy();
    });

    return () => {
      cancelled = true;
      window.cancelAnimationFrame(frame);
      destroy?.();
    };
  }, []);

  return <>{children}</>;
}
