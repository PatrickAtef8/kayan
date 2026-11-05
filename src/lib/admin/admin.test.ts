import { test } from "node:test";
import assert from "node:assert/strict";
import { namesMatch } from "./confirm-name.ts";
import { removeCompanyFiles, listCompanyFiles, type StorageLike } from "./storage-cleanup.ts";

test("typed company name must match exactly (case, inner spacing, other text)", () => {
  assert.equal(namesMatch("شركة النور", "شركة النور"), true);
  assert.equal(namesMatch("  شركة النور \n", "شركة النور"), true);          // paste padding is forgiven
  assert.equal(namesMatch("شركة  النور", "شركة النور"), false);             // inner spacing is not
  assert.equal(namesMatch("Acme", "acme"), false);                          // case matters
  assert.equal(namesMatch("Acme", "Acme Inc"), false);
  assert.equal(namesMatch("", ""), false);                                  // an empty name can never be "confirmed"
  assert.equal(namesMatch(undefined, "Acme"), false);
  assert.equal(namesMatch("Caf\u00e9", "Cafe\u0301"), true);                // same text, different Unicode encoding
});

function fakeBucket(files: string[], failRemove = false) {
  const removed: string[] = [];
  const s: StorageLike = {
    async list(prefix, { limit, offset }) {
      const kids = new Map<string, boolean>();
      for (const f of files) if (f.startsWith(prefix + "/")) { const rest = f.slice(prefix.length + 1); const [head, ...tail] = rest.split("/"); kids.set(head, tail.length === 0); }
      const all = [...kids].map(([name, isFile]) => ({ name, id: isFile ? "x" : null }));
      return { data: all.slice(offset, offset + limit), error: null };
    },
    async remove(paths) { if (failRemove) return { error: { message: "boom" } }; removed.push(...paths); return { error: null }; },
  };
  return { s, removed };
}

test("storage cleanup walks nested folders and removes only that company's files", async () => {
  const org = "aaaaaaaa-0000-0000-0000-000000000001";
  const { s, removed } = fakeBucket([`${org}/expense/1/a.pdf`, `${org}/customer/2/b.png`, `${org}/x.txt`, "other-org/expense/1/z.pdf"]);
  const r = await removeCompanyFiles(s, org);
  assert.equal(r.found, 3); assert.equal(r.removed, 3); assert.equal(r.failed, 0);
  assert.ok(removed.every((p) => p.startsWith(org + "/")));
});

test("a path outside the company folder or with .. is never deleted, even if the archive lists it", async () => {
  const org = "aaaaaaaa-0000-0000-0000-000000000001";
  const { s, removed } = fakeBucket([]);
  await removeCompanyFiles(s, org, ["other-org/a.pdf", `${org}/../other/a.pdf`, `${org}/ok.pdf`]);
  assert.deepEqual(removed, [`${org}/ok.pdf`]);
});

test("removal failures are reported, not thrown", async () => {
  const org = "aaaaaaaa-0000-0000-0000-000000000001";
  const { s } = fakeBucket([`${org}/a.pdf`], true);
  const r = await removeCompanyFiles(s, org);
  assert.equal(r.failed, 1); assert.equal(r.removed, 0); assert.deepEqual(r.errors, ["boom"]);
});

test("more than 1000 files in one folder are all listed (paged)", async () => {
  const org = "aaaaaaaa-0000-0000-0000-000000000001";
  const { s } = fakeBucket(Array.from({ length: 2300 }, (_, i) => `${org}/f${i}.pdf`));
  assert.equal((await listCompanyFiles(s, org)).paths.length, 2300);
});
