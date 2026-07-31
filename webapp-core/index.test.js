import test from "node:test";
import assert from "node:assert/strict";
import {
  CatalogStore,
  CheckoutController,
  createCatalogSnapshot,
  pageSizeForViewport
} from "./index.js";

function documentWithProducts(count) {
  return {
    data: Array.from({ length: count }, (_, index) => ({
      type: "product",
      id: `product_${String(index + 1).padStart(4, "0")}`,
      attributes: {
        name: `Product ${index + 1}`,
        short_name: `P${index + 1}`,
        button_label: `Product ${index + 1}`,
        position: index,
        status: "active",
        metadata: {
          category: index % 2 === 0 ? "digital" : "crypto"
        },
        price: {
          amount: String(index + 1),
          amount_usdt: String(index + 1),
          currency: "USDT"
        }
      }
    })),
    meta: {
      schema_version: 1,
      snapshot_id: "snapshot-1488",
      generated_at: "2026-07-31T17:00:00.000000Z",
      count,
      complete: true,
      pagination: "client",
      currency: "USDT",
      locale: "uk_UA"
    }
  };
}

test("paginates 1488 loaded products entirely in memory", () => {
  const snapshot = createCatalogSnapshot(documentWithProducts(1488));
  const store = new CatalogStore(snapshot, { pageSize: 6 });

  assert.equal(store.view().pageCount, 248);
  assert.deepEqual(
    store.view().products.map((product) => product.id),
    ["product_0001", "product_0002", "product_0003", "product_0004", "product_0005", "product_0006"]
  );

  const second = store.next();
  assert.equal(second.page, 2);
  assert.deepEqual(
    second.products.map((product) => product.id),
    ["product_0007", "product_0008", "product_0009", "product_0010", "product_0011", "product_0012"]
  );

  const third = store.next();
  assert.equal(third.page, 3);
  assert.equal(third.products[0].id, "product_0013");
  assert.equal(snapshot.products.length, 1488);
});

test("search and category filtering do not mutate the snapshot", () => {
  const snapshot = createCatalogSnapshot(documentWithProducts(24));
  const store = new CatalogStore(snapshot);

  const filtered = store.setCategory("crypto");
  assert.equal(filtered.totalProducts, 12);
  assert.equal(snapshot.products.length, 24);

  const searched = store.setQuery("Product 10");
  assert.deepEqual(searched.products.map((product) => product.id), ["product_0010"]);
  assert.equal(snapshot.products.length, 24);
});

test("viewport policy keeps portrait pages at six and expands landscape locally", () => {
  assert.equal(pageSizeForViewport({ width: 390, height: 600 }), 6);
  assert.equal(pageSizeForViewport({ width: 800, height: 390 }), 12);
  assert.equal(pageSizeForViewport({ width: 1024, height: 600 }), 18);
});

test("page size changes preserve the first visible product", () => {
  const store = new CatalogStore(createCatalogSnapshot(documentWithProducts(60)), { pageSize: 6 });
  store.goTo(3);
  const before = store.view().products[0].id;
  const after = store.setPageSize(12);

  assert.equal(before, "product_0013");
  assert.equal(after.products[0].id, "product_0013");
});

test("checkout requests happen only after explicit user actions", async () => {
  const calls = [];
  const controller = new CheckoutController({
    async quote(sku) {
      calls.push(["quote", sku]);
      return { id: "quote-1", attributes: { expires_at: "2026-07-31T18:00:00Z" } };
    },
    async accept(quoteId) {
      calls.push(["accept", quoteId]);
      return { id: "order-1", attributes: { status: "pending" } };
    },
    async refresh(orderId) {
      calls.push(["refresh", orderId]);
      return { id: orderId, attributes: { status: "succeeded" } };
    }
  });
  const product = createCatalogSnapshot(documentWithProducts(1)).products[0];

  assert.deepEqual(calls, []);
  await controller.quote(product);
  await controller.accept();
  await controller.refresh();

  assert.deepEqual(calls, [
    ["quote", "product_0001"],
    ["accept", "quote-1"],
    ["refresh", "order-1"]
  ]);
  assert.equal(controller.state.status, "succeeded");
});

test("selecting another product resets the quote and blocks stale completion", async () => {
  let resolveFirstQuote;
  const controller = new CheckoutController({
    quote() {
      return new Promise((resolve) => { resolveFirstQuote = resolve; });
    },
    async accept() {
      throw new Error("accept must not run");
    },
    async refresh() {
      throw new Error("refresh must not run");
    }
  });
  const snapshot = createCatalogSnapshot(documentWithProducts(2));
  const first = snapshot.products[0];
  const second = snapshot.products[1];

  const pending = controller.quote(first);
  controller.reset(second);
  resolveFirstQuote({ id: "stale-quote", attributes: {} });
  await pending;

  assert.equal(controller.state.status, "idle");
  assert.equal(controller.state.product.id, second.id);
  assert.throws(() => controller.accept(), /quote must be loaded/);
});

test("reset without a selection returns checkout to a clean idle state", () => {
  const controller = new CheckoutController({
    async quote() {},
    async accept() {},
    async refresh() {}
  });

  assert.deepEqual(controller.reset(), { status: "idle" });
});
