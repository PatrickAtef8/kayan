export const COMMISSION_BASIS_LABELS: Record<string, string> = {
  sales_value: "إجمالي المبيعات",
  net_sales: "صافي المبيعات (بعد الخصم)",
  gross_profit: "إجمالي الربح",
  collected_amount: "المبلغ المحصّل",
};

export const COMMISSION_BASIS_OPTIONS = Object.entries(COMMISSION_BASIS_LABELS).map(([value, label]) => ({ value, label }));
