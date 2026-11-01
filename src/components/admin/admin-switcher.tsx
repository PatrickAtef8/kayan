import Link from "next/link";
import clsx from "clsx";
import { LayoutDashboard, ShieldCheck } from "lucide-react";

// The two doors a platform administrator has, side by side, on both sides:
//   «لوحة التحكم»        → the company dashboard: the whole application exactly as an owner uses it (demos, testing)
//   «لوحة تحكم الأدمن»   → the platform back office (/admin)
// Only ever rendered for a verified administrator (the layouts decide that on the server).
export function AdminSwitcher({ current, className }: { current: "app" | "admin"; className?: string }) {
  const base = "inline-flex items-center gap-2 whitespace-nowrap rounded-lg px-3.5 py-2 text-sm transition-colors";
  return (
    <nav aria-label="التنقل بين اللوحتين" className={clsx("inline-flex items-center gap-1 rounded-xl border border-borderSoft bg-white p-1", className)}>
      <Link href="/dashboard" aria-current={current === "app" ? "page" : undefined} className={clsx(base, current === "app" ? "bg-charcoal font-medium text-ivory" : "text-charcoal/60 hover:bg-paper hover:text-charcoal")}>
        <LayoutDashboard size={16} className="shrink-0" />لوحة التحكم
      </Link>
      <Link href="/admin" aria-current={current === "admin" ? "page" : undefined} className={clsx(base, current === "admin" ? "bg-charcoal font-medium text-ivory" : "text-charcoal/60 hover:bg-paper hover:text-charcoal")}>
        <ShieldCheck size={16} className="shrink-0" />لوحة تحكم الأدمن
      </Link>
    </nav>
  );
}
