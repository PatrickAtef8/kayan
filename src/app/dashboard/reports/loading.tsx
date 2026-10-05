import { PageSkeleton } from "@/components/ui/page-skeleton";

// The section's header and tabs stay on screen (they live in layout.tsx);
// only the content area below them shows this placeholder.
export default function Loading() {
  return <PageSkeleton header={false} />;
}
