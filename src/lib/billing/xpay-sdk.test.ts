import { test } from "node:test";
import assert from "node:assert/strict";
import { KAYAN_APPEARANCE, loadXpaySdk, openEmbeddedCheckout, successPath, XPAY_SDK_URL, type SdkEnv, type XpayCheckoutOptions, type XpayFactory } from "./xpay-sdk.ts";

// A stand-in page: appending the script either "loads" it (and defines window.XPay) or fails it, like a browser would.
function fakeEnv(behaviour: "load" | "error" | "load-without-global" | "hang", factory?: XpayFactory) {
  const win: SdkEnv["win"] = {};
  const appended: string[] = [];
  const env: SdkEnv = {
    win,
    doc: {
      createElement: () => ({ src: "", async: false, onload: null, onerror: null, remove() {} }),
      head: { appendChild(node: never) {
        const s = node as { src: string; onload: (() => void) | null; onerror: (() => void) | null };
        appended.push(s.src);
        queueMicrotask(() => {
          if (behaviour === "load") { win.XPay = factory!; s.onload?.(); }
          else if (behaviour === "load-without-global") s.onload?.();
          else if (behaviour === "error") s.onerror?.();
        });
      } },
    },
  };
  return { env, appended, win };
}

function fakeFactory() {
  const log: string[] = [];
  let opts!: XpayCheckoutOptions; let key = "";
  const factory: XpayFactory = (pk) => { key = pk; return { checkout(o) { opts = o; return { open: () => log.push("open"), close: () => log.push("close"), destroy: () => log.push("destroy") }; } }; };
  return { factory, log, get opts() { return opts; }, get key() { return key; } };
}

test("the script is loaded from XPay's own host, and its global is returned", async () => {
  const f = fakeFactory(); const { env, appended } = fakeEnv("load", f.factory);
  assert.equal(await loadXpaySdk(env), f.factory);
  assert.deepEqual(appended, [XPAY_SDK_URL]);
  assert.equal(XPAY_SDK_URL, "https://checkout.xpay.app/v1/sdk.js");
});

test("an already loaded SDK is reused without adding a second script", async () => {
  const f = fakeFactory(); const { env, appended, win } = fakeEnv("load", f.factory);
  win.XPay = f.factory;
  assert.equal(await loadXpaySdk(env), f.factory);
  assert.deepEqual(appended, []);
});

test("a script that cannot load (ad blocker, offline), loads without defining XPay, or hangs, is a rejection the page can show", async () => {
  await assert.rejects(loadXpaySdk(fakeEnv("error").env), /failed to load/);
  await assert.rejects(loadXpaySdk(fakeEnv("load-without-global").env), /global missing/);
  await assert.rejects(loadXpaySdk(fakeEnv("hang").env, 20), /timeout/);
});

test("the window opens with the session secret, Arabic, Kayan's colours; closing and completing are reported", async () => {
  const f = fakeFactory(); const { env } = fakeEnv("load", f.factory);
  const events: string[] = [];
  const h = await openEmbeddedCheckout({ publishableKey: "pk_live_abc", clientSecret: "cs_live_x_secret_y", onComplete: () => events.push("complete"), onClose: () => events.push("close"), onError: () => events.push("error") }, env);
  assert.equal(f.key, "pk_live_abc");
  assert.equal(f.opts.clientSecret, "cs_live_x_secret_y");
  assert.equal(f.opts.mode, "modal");
  assert.equal(f.opts.locale, "ar");
  assert.deepEqual(f.opts.appearance, KAYAN_APPEARANCE);
  assert.deepEqual(f.log, ["open"]);
  f.opts.onClose?.(); f.opts.onError?.({ message: "declined" }); f.opts.onComplete?.({ status: "succeeded", redirectUrl: "https://evil.example" });
  assert.deepEqual(events, ["close", "error", "complete"]);
  h.reopen(); h.destroy();
  assert.deepEqual(f.log, ["open", "open", "destroy"]);
});

test("the page after a finished payment is Kayan's own result page for that order (never an address XPay hands back)", () => {
  assert.equal(successPath("11111111-1111-1111-1111-111111111111"), "/checkout/success?order=11111111-1111-1111-1111-111111111111");
  assert.equal(successPath("a b&c"), "/checkout/success?order=a%20b%26c");
});
