"use client";

import { useState } from "react";
import { useRouter, usePathname, useSearchParams } from "next/navigation";
import { startNavigation } from "@/lib/navigation-state";
import { ModernSelect } from "@/components/ui/select";

// A dropdown that lives in the URL (?warehouse=…, ?channel=…). Every report page
// reads its own searchParams, so this stays generic: it only swaps one param and
// keeps all the others (period, from/to, group, …) untouched.
export function ParamSelect({
  param,
  value,
  options,
  placeholder,
  clearLabel,
}: {
  param: string;
  value: string;
  options: { value: string; label: string }[];
  placeholder: string;
  clearLabel: string;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [selected, setSelected] = useState(value);
  const [prev, setPrev] = useState(value);
  if (value !== prev) {
    setPrev(value);
    setSelected(value);
  }

  function change(next: string) {
    setSelected(next);
    const params = new URLSearchParams(searchParams.toString());
    if (next) params.set(param, next);
    else params.delete(param);
    params.delete("page");
    const href = `${pathname}?${params.toString()}`;
    startNavigation(href);
    router.push(href, { scroll: false });
  }

  return (
    <div className="w-48 shrink-0">
      <ModernSelect value={selected} onChange={change} options={options} placeholder={placeholder} clearLabel={clearLabel} />
    </div>
  );
}
