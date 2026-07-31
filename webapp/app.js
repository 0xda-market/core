import {
  CatalogStore,
  createCatalogSnapshot,
  formatPrice,
  pageSizeForViewport
} from "/webapp-core/index.js";

const CATALOG_BOOTSTRAP_TIMEOUT_MS = 15_000;

const elements = {
  category: document.querySelector("#category"),
  dialog: document.querySelector("#product-dialog"),
  dialogCategory: document.querySelector("#dialog-category"),
  dialogName: document.querySelector("#dialog-name"),
  dialogPrice: document.querySelector("#dialog-price"),
  home: document.querySelector("#home"),
  next: document.querySelector("#next"),
  previous: document.querySelector("#previous"),
  products: document.querySelector("#products"),
  search: document.querySelector("#search"),
  snapshot: document.querySelector("#snapshot"),
  status: document.querySelector("#status")
};

let store;
let bootstrapRequests = 0;

function locale() {
  const normalized = String(navigator.language || "en-US").replace("-", "_");
  return /^[a-z]{2}_[A-Z]{2}$/.test(normalized) ? normalized : "en_US";
}

async function loadCatalog() {
  bootstrapRequests += 1;
  if (bootstrapRequests > 1) throw new Error("catalog bootstrap must be requested exactly once");

  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), CATALOG_BOOTSTRAP_TIMEOUT_MS);

  try {
    const response = await fetch(
      `/v1/webapp/bootstrap?${new URLSearchParams({ locale: locale(), currency: "USDT" })}`,
      {
        headers: { accept: "application/json" },
        signal: controller.signal
      }
    );
    if (!response.ok) throw new Error(`catalog bootstrap failed with HTTP ${response.status}`);

    return createCatalogSnapshot(await response.json());
  } catch (error) {
    if (error?.name === "AbortError") {
      throw new Error("catalog bootstrap timed out after 15 seconds");
    }
    throw error;
  } finally {
    window.clearTimeout(timeout);
  }
}

function renderCategories(snapshot) {
  for (const category of snapshot.categories) {
    const option = document.createElement("option");
    option.value = category.id;
    option.textContent = category.label;
    elements.category.append(option);
  }
}

function render() {
  const view = store.view();
  elements.products.replaceChildren(...view.products.map(productCard));
  elements.previous.disabled = !view.hasPrevious;
  elements.next.disabled = !view.hasNext;
  elements.status.textContent = `${view.totalProducts} products · page ${view.page}/${view.pageCount}`;
}

function productCard(product) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "product";
  button.dataset.productId = product.id;

  const category = document.createElement("span");
  category.className = "product-category";
  category.textContent = product.category.label;

  const name = document.createElement("strong");
  name.textContent = product.attributes.button_label || product.attributes.name;

  const price = document.createElement("span");
  price.className = "product-price";
  price.textContent = formatPrice(product) || "Price unavailable";

  button.append(category, name, price);
  button.addEventListener("click", () => showProduct(product));
  return button;
}

function showProduct(product) {
  elements.dialogCategory.textContent = product.category.label;
  elements.dialogName.textContent = product.attributes.name;
  elements.dialogPrice.textContent = formatPrice(product) || "Price unavailable";
  elements.dialog.showModal();
}

function syncViewport() {
  if (!store) return;
  store.setPageSize(pageSizeForViewport({ width: window.innerWidth, height: window.innerHeight }));
  render();
}

async function start() {
  const snapshot = await loadCatalog();
  store = new CatalogStore(snapshot, {
    pageSize: pageSizeForViewport({ width: window.innerWidth, height: window.innerHeight })
  });
  elements.snapshot.textContent = `${snapshot.id.slice(0, 8)} · ${snapshot.count}`;
  renderCategories(snapshot);
  render();
}

elements.search.addEventListener("input", (event) => {
  if (!store) return;
  store.setQuery(event.currentTarget.value);
  render();
});
elements.category.addEventListener("change", (event) => {
  if (!store) return;
  store.setCategory(event.currentTarget.value);
  render();
});
elements.previous.addEventListener("click", () => {
  if (!store) return;
  store.previous();
  render();
});
elements.home.addEventListener("click", () => {
  if (!store) return;
  elements.category.value = "";
  store.setCategory(null);
  store.home();
  render();
});
elements.next.addEventListener("click", () => {
  if (!store) return;
  store.next();
  render();
});
window.addEventListener("resize", syncViewport, { passive: true });

start().catch((error) => {
  elements.status.textContent = error.message;
  elements.status.dataset.error = "true";
});
