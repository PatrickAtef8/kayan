import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Tag } from "lucide-react";

export default function OffersPage() {
  return (
    <div>
      <PageHeader title="العروض" />
      <Card className="flex flex-col items-center gap-3 p-12 text-center">
        <div className="flex h-11 w-11 items-center justify-center rounded-full bg-paper text-charcoal/40">
          <Tag size={18} strokeWidth={1.8} />
        </div>
        <p className="max-w-sm text-sm text-charcoal/50">
          وحدة العروض الشهرية قيد الانتظار حتى يتم تحديد آلية العمل بدقة مع فريق العمل. يمكنك تعطيل هذه الوحدة من
          الإعدادات إذا لم تكن بحاجة إليها الآن.
        </p>
      </Card>
    </div>
  );
}
