"use client";

import { useEffect, useRef } from "react";
import { m, useInView, useMotionValue, useSpring } from "framer-motion";

// Counts up from 0 to `value` once it scrolls into view. One quiet motion
// detail rather than a decorative effect — the whole point of this pass.
export function NumberTicker({ value, suffix = "" }: { value: number; suffix?: string }) {
  const ref = useRef<HTMLSpanElement>(null);
  const isInView = useInView(ref, { once: true, margin: "-80px" });
  const motionValue = useMotionValue(0);
  const springValue = useSpring(motionValue, { damping: 26, stiffness: 50 });

  useEffect(() => {
    if (isInView) motionValue.set(value);
  }, [isInView, value, motionValue]);

  useEffect(() => {
    return springValue.on("change", (latest) => {
      if (ref.current) ref.current.textContent = Math.round(latest).toLocaleString("en-US") + suffix;
    });
  }, [springValue, suffix]);

  return <m.span ref={ref} dir="ltr">0{suffix}</m.span>;
}
