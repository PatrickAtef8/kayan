import clsx from "clsx";

// Small inline spinner for buttons and row actions (inherits the text colour).
export function Spinner({ size = 14, className }: { size?: number; className?: string }) {
  return <span role="status" aria-label="جارٍ التنفيذ" className={clsx("inline-block shrink-0 animate-spin rounded-full border-2 border-current border-t-transparent", className)} style={{ width: size, height: size }} />;
}
