import Link from "next/link";

export default function NotFound() {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-4 bg-paper px-6 text-center">
      <p className="text-sm font-medium text-sage">٤٠٤</p>
      <h1 className="text-2xl font-semibold text-charcoal">الصفحة غير موجودة</h1>
      <p className="max-w-sm text-sm text-charcoal/50">قد يكون الرابط غير صحيح أو تم نقل هذه الصفحة.</p>
      <Link href="/dashboard" className="mt-2 rounded-xl bg-charcoal px-4 py-2.5 text-xs font-medium text-ivory transition-colors hover:bg-sage">
        العودة إلى مركز العمل
      </Link>
    </div>
  );
}
