import { PartyBalanceReport } from "../party-balance-report";

export default async function CustomersReportPage(props: { searchParams: Promise<{ party?: string; q?: string }> }) {
  const searchParams = await props.searchParams;
  return <PartyBalanceReport type="customer" basePath="/dashboard/reports/customers" searchParams={searchParams} />;
}
