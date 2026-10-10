import { PartyBalanceReport } from "../party-balance-report";

export default async function SuppliersReportPage(props: { searchParams: Promise<{ party?: string }> }) {
  const searchParams = await props.searchParams;
  return <PartyBalanceReport type="supplier" basePath="/dashboard/reports/suppliers" searchParams={searchParams} />;
}
