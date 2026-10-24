// "نوع المصروف" decides HOW the money is accounted for (and whether a rep is needed).
// "التصنيف" (a separate, free-form label) only groups expenses in the reports.
export type ExpenseTypeInfo = {
  value: "operating" | "rep_expense" | "salary" | "commission_payout";
  label: string;
  examples: string; // what the user would actually be paying
  effect: string; // what the system does with it
  needsRep: boolean;
};

export const EXPENSE_TYPES: ExpenseTypeInfo[] = [
  {
    value: "operating",
    label: "مصروف تشغيلي",
    examples: "إيجار، كهرباء، إنترنت، مستلزمات",
    effect: "يُخصم من الخزنة ومن الربح",
    needsRep: false,
  },
  {
    value: "rep_expense",
    label: "مصاريف مندوب",
    examples: "بنزين، انتقالات، عهدة المندوب",
    effect: "يُخصم من الخزنة ومن الربح",
    needsRep: true,
  },
  {
    value: "salary",
    label: "مرتب مندوب",
    examples: "الراتب الأساسي للمندوب",
    effect: "يُخصم من الخزنة ومن الربح",
    needsRep: true,
  },
  {
    value: "commission_payout",
    label: "صرف عمولة مندوب",
    examples: "تسليم عمولة مستحقة للمندوب",
    effect: "يُخصم من الخزنة فقط (العمولة خُصمت من الربح وقت استحقاقها) ولا يزيد عن المستحق",
    needsRep: true,
  },
];

export const EXPENSE_TYPE_LABELS: Record<string, string> = Object.fromEntries(EXPENSE_TYPES.map((t) => [t.value, t.label]));
