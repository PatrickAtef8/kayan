"use client";

import { useEffect, useRef, useState } from "react";
import { Check, ChevronDown } from "lucide-react";

export function ModernSelect({
  name,
  value: controlledValue,
  onChange,
  defaultValue = "",
  placeholder = "اختر تصنيفًا",
  options,
  allowClear = true,
  clearLabel = "بدون تصنيف",
}: {
  name?: string;
  value?: string;
  onChange?: (value: string) => void;
  defaultValue?: string;
  placeholder?: string;
  options: { value: string; label: string }[];
  allowClear?: boolean;
  clearLabel?: string;
}) {
  const [open, setOpen] = useState(false);
  const [internalValue, setInternalValue] = useState(defaultValue);
  const value = controlledValue !== undefined ? controlledValue : internalValue;
  const setValue = (next: string) => {
    if (controlledValue === undefined) setInternalValue(next);
    onChange?.(next);
  };
  const ref = useRef<HTMLDivElement>(null);
  const selected = options.find((option) => option.value === value);

  useEffect(() => {
    const close = (event: MouseEvent) => {
      if (ref.current && !ref.current.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, []);

  return (
    <div ref={ref} className="relative">
      {name && <input type="hidden" name={name} value={value} />}
      <button
        type="button"
        onClick={() => setOpen((current) => !current)}
        aria-haspopup="listbox"
        aria-expanded={open}
        className={`flex w-full items-center justify-between rounded-xl border px-3.5 py-3 text-right text-sm outline-none transition-all ${open ? "border-sage bg-white ring-4 ring-sage/10" : "border-borderSoft bg-paper hover:border-sage/60"}`}
      >
        <span className={selected ? "text-charcoal" : "text-charcoal/40"}>{selected?.label ?? placeholder}</span>
        <ChevronDown size={17} className={`text-charcoal/40 transition-transform duration-200 ${open ? "rotate-180 text-sage" : ""}`} />
      </button>
      {open && (
        <div role="listbox" className="absolute right-0 z-30 mt-2 max-h-60 w-full overflow-y-auto rounded-xl border border-borderSoft bg-white p-1.5 shadow-[0_18px_40px_rgba(28,28,26,0.12)]">
          {allowClear && (
            <button type="button" role="option" aria-selected={value === ""} onClick={() => { setValue(""); setOpen(false); }} className="flex w-full items-center justify-between rounded-lg px-3 py-2.5 text-right text-sm text-charcoal/50 transition-colors hover:bg-paper hover:text-charcoal">
              {clearLabel}
              {value === "" && <Check size={16} className="text-sage" />}
            </button>
          )}
          {options.map((option) => (
            <button key={option.value} type="button" role="option" aria-selected={value === option.value} onClick={() => { setValue(option.value); setOpen(false); }} className={`flex w-full items-center justify-between rounded-lg px-3 py-2.5 text-right text-sm transition-colors ${value === option.value ? "bg-sageSoft text-sage" : "text-charcoal hover:bg-paper"}`}>
              {option.label}
              {value === option.value && <Check size={16} />}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
