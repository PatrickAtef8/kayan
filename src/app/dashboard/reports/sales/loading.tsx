import { PageSkeleton } from "@/components/ui/page-skeleton";

// Sits one level below the reports loading boundary, so switching between this section's sub-tabs keeps the
// section header and its tab bar on screen; only the content under them shows the placeholder.
export default function Loading() {
  return <PageSkeleton header={false} />;
}
