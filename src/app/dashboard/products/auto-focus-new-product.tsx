"use client";

import { useEffect } from "react";
import { useSearchParams } from "next/navigation";

export function AutoFocusNewProduct() {
  const searchParams = useSearchParams();

  useEffect(() => {
    if (searchParams.get("new") !== "1") return;
    const form = document.getElementById("add-product-form");
    form?.scrollIntoView({ behavior: "smooth", block: "start" });
    document.getElementById("product-name-input")?.focus();
  }, [searchParams]);

  return null;
}
