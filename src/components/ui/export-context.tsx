"use client";

import { createContext, useContext } from "react";

// The signed-in organisation's name, so every exported file can carry the company's name in its header without each
// report page having to pass it down.
const OrgNameContext = createContext<string | undefined>(undefined);

export function ExportOrgProvider({ orgName, children }: { orgName?: string; children: React.ReactNode }) {
  return <OrgNameContext.Provider value={orgName}>{children}</OrgNameContext.Provider>;
}

export function useExportOrgName(): string | undefined {
  return useContext(OrgNameContext);
}
