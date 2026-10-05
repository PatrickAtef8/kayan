import { PartyBalanceReport } from "../party-balance-report";

export default function CustomersReportPage({ searchParams }: { searchParams: { party?: string } }) {
  return <PartyBalanceReport type="customer" basePath="/dashboard/reports/customers" searchParams={searchParams} />;
}
