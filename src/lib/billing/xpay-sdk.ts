// Browser side of the in-page payment (XPay "drop-in", inline): loads XPay's script once and mounts the checkout inside a container on Kayan's own
// /checkout/pay page. Client-safe: no secrets, no server-only import. The only key it ever sees is the PUBLISHABLE one (pk_…), which XPay made public.
// Docs: https://docs.xpay.app/en/integrate/integration-patterns/drop-in  and  https://docs.xpay.app/en/sdk/sdk-js
//
// The script comes from XPay's own host (https://checkout.xpay.app/v1/sdk.js) and exposes a global `XPay(publishableKey)`; card data is typed inside
// XPay's iframe and never reaches Kayan's page or servers. XPay's form also shows the Fawry reference, the 3-D Secure step and Apple Pay.

export const XPAY_SDK_URL = "https://checkout.xpay.app/v1/sdk.js";

export type XpayCompleteResult = { status?: string; paymentIntentId?: string; chargeId?: string; redirectUrl?: string };
export type XpayCheckoutOptions = {
  clientSecret: string;
  mode: "modal" | "inline";
  /** inline mode: the element (or CSS selector) the form is mounted in */
  container?: string | HTMLElement;
  locale?: "ar" | "en";
  appearance?: {
    colorMode?: "light" | "dark" | "system"; borderStyle?: "rounded" | "sharp" | "pill"; spacing?: "condensed" | "normal" | "spacious";
    inputSize?: "small" | "medium" | "large"; inputStyle?: "outlined" | "flat" | "filled"; formLayout?: "compact" | "spacious";
    colors?: Record<string, string>; fontFamily?: string;
  };
  onReady?: (session?: unknown) => void;
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

/** Kayan's own pages around the payment. The result page asks XPay what really happened (the webhook is the authority); an address XPay hands back is never followed. */
export const successPath = (orderId: string) => `/checkout/success?order=${encodeURIComponent(orderId)}`;
export const payPath = (orderId: string) => `/checkout/pay?order=${encodeURIComponent(orderId)}`;

/** Kayan's look inside XPay's form: the same ivory / charcoal / green as the rest of the site, roomy inputs for a phone. */
export const KAYAN_APPEARANCE: NonNullable<XpayCheckoutOptions["appearance"]> = {
  colorMode: "light",
  borderStyle: "rounded",
  spacing: "normal",
  inputSize: "large",
  inputStyle: "outlined",
  formLayout: "spacious",
  colors: {
    primary: "#344E41", primaryForeground: "#F7F6F2",
    background: "#FFFFFF", foreground: "#1C1C1A",
    muted: "#F7F6F2", mutedForeground: "#6F6F6A",
    accent: "#E7EDE8", accentForeground: "#344E41",
    border: "#E5E3DD", input: "#E5E3DD", ring: "#344E41",
    destructive: "#9C4F45",
  },
};

export type MountHandlers = {
  /** the form is on screen */
  onReady: () => void;
  /** the payment finished (cards / ValU: paid; Fawry: the reference was issued and the customer pays at a kiosk) — go to the result page */
  onComplete: () => void;
  /** an attempt did not go through (the form itself shows the reason and a retry) */
  onError: () => void;
};

/** Mounts XPay's form inside `container`. Resolves with a handle to tear it down. Rejects if the script cannot load. */
export async function mountInlineCheckout(input: { publishableKey: string; clientSecret: string; container: HTMLElement } & MountHandlers, env?: SdkEnv): Promise<{ destroy(): void }> {
  const XPay = await loadXpaySdk(env);
  const checkout = XPay(input.publishableKey).checkout({
    clientSecret: input.clientSecret,
    mode: "inline",
    container: input.container,
    locale: "ar",
    appearance: KAYAN_APPEARANCE,
    onReady: () => input.onReady(),
    onComplete: () => input.onComplete(),
    onError: () => input.onError(),
  });
  return { destroy: () => checkout.destroy() };
}
