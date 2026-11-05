"use client";
import { ErrorView } from "@/components/error-view";
export default function AdminError(props: { error: Error & { digest?: string }; reset: () => void }) {
  return <ErrorView {...props} homeHref="/admin" scope="admin" />;
}
