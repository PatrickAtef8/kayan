"use client";

import { forwardRef, useRef, useState, type InputHTMLAttributes } from "react";
import clsx from "clsx";

const BASE =
  "w-full border border-borderSoft bg-white px-3.5 py-3 text-base text-charcoal outline-none transition-colors placeholder:text-charcoal/30 focus:border-sage focus-visible:ring-2 focus-visible:ring-sage/20";

/**
 * Numeric input that behaves the way people expect:
 *  - clicking/tabbing into the box selects the whole value, so typing replaces a "0"
 *    instead of forcing the user to type next to it and delete the zero afterwards;
 *  - a controlled field whose parent stores `Number(e.target.value)` can be cleared
 *    (an empty box no longer snaps back to "0" while the user is typing).
 */
const NumberInput = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement>>(function NumberInput(
  { className, value, onChange, onFocus, onBlur, onMouseUp, ...props },
  ref,
) {
  const [draft, setDraft] = useState<string | null>(null);
  const justFocused = useRef(false);
  const controlled = value !== undefined;

  let shown: InputHTMLAttributes<HTMLInputElement>["value"] = value;
  if (controlled && draft !== null) {
    const parent = Number(value);
    const typed = draft === "" ? 0 : Number(draft);
    // Keep showing what the user typed while it still matches the parent's number
    // (covers "" -> 0 and "1." -> 1 and "-" etc.).
    if (!Number.isNaN(typed) || draft === "") {
      if (typed === parent) shown = draft;
    } else if (draft === "-" || draft === ".") {
      shown = draft;
    }
  }

  return (
    <input
      ref={ref}
      type="number"
      inputMode="decimal"
      className={clsx(BASE, className)}
      {...props}
      {...(controlled ? { value: shown } : {})}
      onChange={(e) => {
        if (controlled) setDraft(e.target.value);
        onChange?.(e);
      }}
      onFocus={(e) => {
        justFocused.current = true;
        e.currentTarget.select();
        onFocus?.(e);
      }}
      onMouseUp={(e) => {
        // Chrome/Safari drop the selection on mouse-up after a click focus; keep it.
        if (justFocused.current) {
          e.preventDefault();
          justFocused.current = false;
        }
        onMouseUp?.(e);
      }}
      onBlur={(e) => {
        justFocused.current = false;
        setDraft(null);
        onBlur?.(e);
      }}
    />
  );
});

export const Input = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement>>(function Input(props, ref) {
  if (props.type === "number") return <NumberInput ref={ref} {...props} />;
  const { className, ...rest } = props;
  return <input ref={ref} className={clsx(BASE, className)} {...rest} />;
});

export function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <div><label className="mb-2 block text-sm text-charcoal/65">{label}</label>{children}</div>;
}
