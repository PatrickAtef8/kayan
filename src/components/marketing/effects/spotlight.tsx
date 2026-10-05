"use client";

import { m } from "framer-motion";

// A slow-drifting blurred gold aurora behind the hero, built from two
// radial-gradient blobs animated with Framer Motion — the same technique
// behind Aceternity's "Spotlight"/"Aurora" effects, written from scratch
// rather than copied, so it's ours to tune (colors, speed, blur radius).
export function Spotlight() {
  return (
    <div className="pointer-events-none absolute inset-0 overflow-hidden">
      <m.div
        className="absolute h-[36rem] w-[36rem] rounded-full bg-brass/20 blur-[120px]"
        style={{ top: "-8rem", right: "-6rem" }}
        animate={{ x: [0, 40, 0], y: [0, 30, 0] }}
        transition={{ duration: 14, repeat: Infinity, ease: "easeInOut" }}
      />
      <m.div
        className="absolute h-[28rem] w-[28rem] rounded-full bg-brassDeep/25 blur-[110px]"
        style={{ bottom: "-6rem", left: "-4rem" }}
        animate={{ x: [0, -30, 0], y: [0, -20, 0] }}
        transition={{ duration: 18, repeat: Infinity, ease: "easeInOut" }}
      />
      <div
        className="absolute inset-0 opacity-[0.06]"
        style={{
          backgroundImage: "radial-gradient(circle at 1px 1px, white 1px, transparent 0)",
          backgroundSize: "36px 36px",
        }}
      />
    </div>
  );
}
