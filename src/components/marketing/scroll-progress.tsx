"use client";

import { m, useScroll, useSpring } from "framer-motion";

export function ScrollProgress() {
  const { scrollYProgress } = useScroll();
  const scaleX = useSpring(scrollYProgress, { stiffness: 120, damping: 28, mass: 0.25 });
  return <m.div style={{ scaleX, transformOrigin: "right" }} className="fixed inset-x-0 top-0 z-[60] h-[3px] bg-sage" aria-hidden="true" />;
}
