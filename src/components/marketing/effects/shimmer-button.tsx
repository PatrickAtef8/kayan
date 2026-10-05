"use client";

import Link from "next/link";

// Animated gold-gradient sheen sweeping across the CTA on hover — a small
// but real "premium" tell, versus a flat single-color button.
export function ShimmerButton({
  href,
  children,
}: {
  href: string;
  children: React.ReactNode;
}) {
  return (
    <Link
      href={href}
      className="group relative inline-flex items-center gap-2 overflow-hidden rounded-card bg-gradient-to-l from-brassDeep via-brass to-brassLight px-6 py-3 text-sm font-semibold text-obsidian shadow-[0_0_30px_-8px_rgba(212,175,55,0.7)] transition-transform hover:scale-[1.03]"
    >
      <span className="relative z-10">{children}</span>
      <span className="absolute inset-0 -translate-x-full bg-gradient-to-l from-transparent via-white/40 to-transparent transition-transform duration-700 group-hover:translate-x-full" />
    </Link>
  );
}
