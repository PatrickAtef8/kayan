import type { ReactNode } from "react";

// A plain number / date / percentage as ONE isolated left-to-right unit (digits never get re-ordered by the Arabic
// text around them). For amounts with currency use <Money />.
export function Num({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <span dir="ltr" className={`num ${className}`.trim()}>
      {children}
    </span>
  );
}
