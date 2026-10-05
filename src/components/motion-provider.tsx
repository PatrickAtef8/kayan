"use client";

import { LazyMotion } from "framer-motion";

// framer-motion's animation engine is loaded asynchronously after first paint
// instead of being part of the initial bundle. Components use the lightweight
// `m.*` elements, which render immediately and start animating as soon as the
// feature set arrives. domAnimation covers everything used in the app
// (animate/variants, exit, whileInView, hover/tap) — no layout/drag features.
const loadFeatures = () => import("./motion-features").then((mod) => mod.default);

export function MotionProvider({ children }: { children: React.ReactNode }) {
  return <LazyMotion features={loadFeatures}>{children}</LazyMotion>;
}
