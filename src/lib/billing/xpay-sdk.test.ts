import { test } from "node:test";
import assert from "node:assert/strict";
import { KAYAN_APPEARANCE, loadXpaySdk, mountInlineCheckout, payPath, successPath, XPAY_SDK_URL, type SdkEnv, type XpayCheckoutOptions, type XpayFactory } from "./xpay-sdk.ts";

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

test("the form is mounted INSIDE the given container (inline), with the session secret, Arabic and Kayan's look; ready / complete / error are reported", async () => {
  const f = fakeFactory(); const { env } = fakeEnv("load", f.factory);
  const container = { id: "box" } as unknown as HTMLElement;
  const events: string[] = [];
  const h = await mountInlineCheckout({ publishableKey: "pk_live_abc", clientSecret: "cs_live_x_secret_y", container, onReady: () => events.push("ready"), onComplete: () => events.push("complete"), onError: () => events.push("error") }, env);
  assert.equal(f.key, "pk_live_abc");
  assert.equal(f.opts.clientSecret, "cs_live_x_secret_y");
  assert.equal(f.opts.mode, "inline");
  assert.equal(f.opts.container, container);
  assert.equal(f.opts.locale, "ar");
  assert.deepEqual(f.opts.appearance, KAYAN_APPEARANCE);
  assert.deepEqual(f.log, []);                       // inline mode is not "opened": it is simply there
  f.opts.onReady?.(); f.opts.onError?.({ message: "declined" }); f.opts.onComplete?.({ status: "succeeded", redirectUrl: "https://evil.example" });
  assert.deepEqual(events, ["ready", "error", "complete"]);
  h.destroy();
  assert.deepEqual(f.log, ["destroy"]);
});

test("a script that cannot load makes mounting reject (the page shows its retry message)", async () => {
  await assert.rejects(mountInlineCheckout({ publishableKey: "pk_test_a", clientSecret: "cs", container: {} as HTMLElement, onReady() {}, onComplete() {}, onError() {} }, fakeEnv("error").env), /failed to load/);
});

test("Kayan's own pages around the payment are plain same-site paths for that order", () => {
  assert.equal(payPath("11111111-1111-1111-1111-111111111111"), "/checkout/pay?order=11111111-1111-1111-1111-111111111111");
  assert.equal(successPath("11111111-1111-1111-1111-111111111111"), "/checkout/success?order=11111111-1111-1111-1111-111111111111");
  assert.equal(successPath("a b&c"), "/checkout/success?order=a%20b%26c");
});
