// Central module catalog — the single place that knows what a module is
// called, its icon-less label, and its base nav route. Both onboarding
// (module selection) and the dashboard sidebar (module-aware nav) read
// from this list, per SRS §9–§11: disabled modules must not appear in the
// UI, and enforcement must also happen server-side (RLS + permission checks).
export const MODULES = [
  { key: "products", label: "المنتجات", href: "/dashboard/products", icon: "Package", core: true },
  { key: "warehouses", label: "المخازن", href: "/dashboard/warehouses", icon: "Warehouse", core: true },
  { key: "customers", label: "العملاء", href: "/dashboard/customers", icon: "Users" },
  { key: "suppliers", label: "الموردين", href: "/dashboard/suppliers", icon: "Truck" },
  { key: "sales", label: "المبيعات", href: "/dashboard/sales", icon: "ShoppingCart" },
  { key: "purchases", label: "المشتريات", href: "/dashboard/purchases", icon: "ShoppingBag" },
  { key: "inventory", label: "المخزون", href: "/dashboard/inventory", icon: "Boxes" },
  { key: "expenses", label: "المصروفات", href: "/dashboard/expenses", icon: "Receipt" },
  { key: "treasury", label: "الخزنة", href: "/dashboard/treasury", icon: "Wallet" },
  { key: "representatives", label: "المندوبين", href: "/dashboard/representatives", icon: "UserCheck" },
  { key: "partners", label: "الشركاء", href: "/dashboard/partners", icon: "Handshake" },
  { key: "offers", label: "العروض", href: "/dashboard/offers", icon: "Tag" },
  { key: "reports", label: "التقارير", href: "/dashboard/reports", icon: "BarChart3", core: true },
] as const;

export type ModuleKey = (typeof MODULES)[number]["key"];

export const DEFAULT_ENABLED_MODULES: ModuleKey[] = [
  "sales",
  "customers",
  "inventory",
  "purchases",
  "suppliers",
  "expenses",
  "treasury",
];
