import { PACKAGE_MODULE_ORDER } from "@/config/pricing.config";

// Free access granted by the platform = every module, no limits (whatever the paid packages currently say).
export const COMPLIMENTARY_ENTITLEMENTS = { modules: [...PACKAGE_MODULE_ORDER], max_members: null, max_warehouses: null } as const;
