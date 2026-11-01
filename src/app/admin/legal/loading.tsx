import { PageSkeleton } from "@/components/ui/page-skeleton";

// Instant placeholder while this admin page loads (a loading boundary does not re-trigger between sibling pages, hence one per section).
export default function Loading() {
  return <PageSkeleton />;
}
