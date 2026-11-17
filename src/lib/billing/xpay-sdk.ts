// Browser side of the in-page payment window (XPay "drop-in"): loads XPay's script once and opens the checkout in a window on Kayan's own page.
// Client-safe: no secrets, no server-only import. The only key it ever sees is the PUBLISHABLE one (pk_…), which XPay designed to be public.
// Docs: https://docs.xpay.app/en/integrate/integration-patterns/drop-in  and  https://docs.xpay.app/en/sdk/sdk-js
//
// The script comes from XPay's own host (https://checkout.xpay.app/v1/sdk.js) and exposes a global `XPay(publishableKey)`; card data is typed inside
// XPay's iframe and never reaches Kayan's page or servers.

export const XPAY_SDK_URL = "https://checkout.xpay.app/v1/sdk.js";

export type XpayCompleteResult = { status?: string; paymentStatus?: string; paymentIntentId?: string; chargeId?: string; redirectUrl?: string };
export type XpayCheckoutOptions = {
  clientSecret: string;
  mode: "modal";
  locale?: "ar" | "en";
  appearance?: { colorMode?: "light" | "dark" | "system"; borderStyle?: "rounded" | "sharp" | "pill"; colors?: Record<string, string> };
  onReady?: () => void;
  onComplete?: (result: XpayCompleteResult) => void;
  onClose?: () => void;
  onError?: (error: { message?: string; code?: string }) => void;
};
export type XpayCheckout = { open(): void; close(): void; destroy(): void };
export type XpayFactory = (publishableKey: string) => { checkout(options: XpayCheckoutOptions): XpayCheckout };

/** Just enough of the page to load a script: a real browser in production, a stand-in in tests. */
export type SdkEnv = {
  doc: { createElement(tag: "script"): { src: string; async: boolean; onload: (() => void) | null; onerror: (() => void) | null; remove?: () => void }; head: { appendChild(node: never): unknown } };
  win: { XPay?: XpayFactory };
};

let cached: Promise<XpayFactory> | null = null;

/** Loads XPay's script (once per page) and resolves with its `XPay` factory. Rejects if it cannot be loaded (ad blocker, offline, blocked by policy). */
export function loadXpaySdk(env?: SdkEnv, timeoutMs = 15_000): Promise<XpayFactory> {
  const e: SdkEnv | null = env ?? (typeof window === "undefined" ? null : { doc: document as unknown as SdkEnv["doc"], win: window as unknown as SdkEnv["win"] });
  if (!e) return Promise.reject(new Error("no browser"));
  if (e.win.XPay) return Promise.resolve(e.win.XPay);
  if (!env && cached) return cached;
  const p = new Promise<XpayFactory>((resolve, reject) => {
    const script = e.doc.createElement("script");
    const fail = (why: string) => { clearTimeout(timer); script.remove?.(); if (!env) cached = null; reject(new Error(why)); };   // a failed load can be retried
    const timer = setTimeout(() => fail("timeout"), timeoutMs);
    script.src = XPAY_SDK_URL;
    script.async = true;
    script.onload = () => { clearTimeout(timer); e.win.XPay ? resolve(e.win.XPay) : fail("XPay global missing"); };
    script.onerror = () => fail("script failed to load");
    e.doc.head.appendChild(script as never);
  });
  if (!env) cached = p;
  return p;
}

/** The page Kayan sends the customer to once the window reports a finished payment: it asks XPay what really happened (the webhook is the authority). */
export const successPath = (orderId: string) => `/checkout/success?order=${encodeURIComponent(orderId)}`;

/** Kayan's look inside XPay's window: calm, the same green as the buttons. */
export const KAYAN_APPEARANCE: NonNullable<XpayCheckoutOptions["appearance"]> = {
  colorMode: "light",
  borderStyle: "rounded",
  colors: { primary: "#344E41", primaryForeground: "#F7F6F2" },
};

export type OpenHandlers = {
  /** the payment finished (cards / ValU: paid; Fawry: waiting for the customer to pay at a kiosk) — go to the result page */
  onComplete: () => void;
  /** the window was closed without finishing */
  onClose: () => void;
  /** an attempt did not go through (the window itself shows the reason and a retry) */
  onError: () => void;
};

/** Opens the window. Resolves with a handle to re-open or tear it down. Rejects if the script cannot load. */
export async function openEmbeddedCheckout(input: { publishableKey: string; clientSecret: string } & OpenHandlers, env?: SdkEnv): Promise<{ reopen(): void; destroy(): void }> {
  const XPay = await loadXpaySdk(env);
  const checkout = XPay(input.publishableKey).checkout({
    clientSecret: input.clientSecret,
    mode: "modal",
    locale: "ar",
    appearance: KAYAN_APPEARANCE,
    onComplete: () => input.onComplete(),
    onClose: () => input.onClose(),
    onError: () => input.onError(),
  });
  checkout.open();
  return { reopen: () => checkout.open(), destroy: () => checkout.destroy() };
}
