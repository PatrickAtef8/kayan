import { PageSkeleton } from "@/components/ui/page-skeleton";

// Instant placeholder while a top-level dashboard section loads. Sections with
// sub-pages (settings, reports, sales, purchases) have their own loading.tsx,
// because this one does not re-trigger when moving between their children.
export default function DashboardLoading() {
  return <PageSkeleton />;
}
