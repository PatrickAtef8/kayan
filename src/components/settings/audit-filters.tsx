"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { ModernSelect } from "@/components/ui/select";
import { ENTITY_OPTIONS } from "./audit-entities";

export function AuditFilters({ entity }: { entity: string }) {
  const router = useRouter();
  const searchParams = useSearchParams();

  function setEntity(value: string) {
    const params = new URLSearchParams(searchParams.toString());
    if (value) params.set("entity", value);
    else params.delete("entity");
    router.push(`?${params.toString()}`, { scroll: false });
  }

  return (
    <div className="w-48 shrink-0">
      <ModernSelect value={entity} onChange={setEntity} allowClear={false} options={ENTITY_OPTIONS} />
    </div>
  );
}

