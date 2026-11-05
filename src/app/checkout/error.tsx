"use client";
import { ErrorView } from "@/components/error-view";
export default function CheckoutError(props: { error: Error & { digest?: string }; reset: () => void }) {
  return <ErrorView {...props} homeHref="/dashboard/billing" scope="checkout" />;
}
