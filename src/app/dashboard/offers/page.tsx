import { notFound } from "next/navigation";

// The Offers module is not finished: it is hidden from the sidebar and settings (src/lib/modules.ts → HIDDEN_MODULE_KEYS) and this URL does not exist.
export default function OffersPage() {
  notFound();
}
