import { PartyBalanceReport } from "../party-balance-report";

export default function SuppliersReportPage({ searchParams }: { searchParams: { party?: string } }) {
  return <PartyBalanceReport type="supplier" basePath="/dashboard/reports/suppliers" searchParams={searchParams} />;
}
