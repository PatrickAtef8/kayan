"use client";
import { ErrorView } from "@/components/error-view";
export default function DashboardError(props: { error: Error & { digest?: string }; reset: () => void }) {
  return <ErrorView {...props} homeHref="/dashboard" scope="dashboard" />;
}
