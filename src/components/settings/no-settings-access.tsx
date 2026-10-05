import { Lock } from "lucide-react";
import { Card } from "@/components/ui/card";

export function NoSettingsAccess({ message }: { message?: string }) {
  return (
    <Card className="flex flex-col items-center gap-3 p-12 text-center">
      <div className="flex h-11 w-11 items-center justify-center rounded-full bg-paper text-charcoal/40">
        <Lock size={18} strokeWidth={1.8} />
      </div>
      <p className="text-sm text-charcoal/50">{message ?? "ليس لديك صلاحية إدارة إعدادات المؤسسة."}</p>
    </Card>
  );
}
