const DEFAULT_PAGE_SIZE = 6;
const LANDSCAPE_PAGE_SIZE = 12;
const WIDE_LANDSCAPE_PAGE_SIZE = 18;

function assert(condition, message) {
  if (!condition) throw new TypeError(message);
}

function immutable(value) {
  if (Array.isArray(value)) {
    value.forEach(immutable);
    return Object.freeze(value);
  }

  if (value && typeof value === "object") {
    Object.values(value).forEach(immutable);
    return Object.freeze(value);
  }

  return value;
}

function normalizeText(value) {
  return String(value ?? "").trim().toLocaleLowerCase();
}

function categoryFor(product) {
  const metadata = product.attributes.metadata ?? {};
  const rawId = metadata.category ?? metadata.family ?? "catalog";
  const id = normalizeText(rawId).replace(/[^a-z0-9_-]+/g, "-") || "catalog";
  const label = String(metadata.category_label ?? rawId ?? "Catalog").trim() || "Catalog";
  return { id, label };
}

function normalizeProduct(resource) {
  assert(resource?.type === "product", "catalog resource must be a product");
  assert(typeof resource.id === "string" && resource.id.length > 0, "product id is required");
  assert(resource.attributes && typeof resource.attributes === "object", "product attributes are required");

  const attributes = resource.attributes;
  const category = categoryFor(resource);
  const searchText = normalizeText([
    resource.id,
    attributes.name,
    attributes.short_name,
    attributes.button_label,
    category.label
  ].filter(Boolean).join(" "));

  return immutable({
    id: resource.id,
    type: resource.type,
    category,
    searchText,
    attributes: { ...attributes }
  });
}

export function createCatalogSnapshot(document) {
  assert(document && typeof document === "object", "catalog document is required");
  assert(Array.isArray(document.data), "catalog document data must be an array");
  assert(document.meta && typeof document.meta === "object", "catalog document meta is required");
  assert(document.meta.complete === true, "catalog snapshot must be complete");
  assert(document.meta.pagination === "client", "catalog snapshot must use client pagination");

  const products = document.data.map(normalizeProduct);
  const categoriesById = new Map();
  for (const product of products) categoriesById.set(product.category.id, product.category);

  return immutable({
    id: String(document.meta.snapshot_id),
    schemaVersion: Number(document.meta.schema_version),
    generatedAt: String(document.meta.generated_at),
    locale: String(document.meta.locale),
    currency: String(document.meta.currency),
    products,
    categories: Array.from(categoriesById.values()),
    count: products.length
  });
}

export function pageSizeForViewport({ width, height }) {
  const safeWidth = Number(width) || 0;
  const safeHeight = Number(height) || 0;
  if (safeWidth <= safeHeight) return DEFAULT_PAGE_SIZE;
  return safeWidth >= 900 ? WIDE_LANDSCAPE_PAGE_SIZE : LANDSCAPE_PAGE_SIZE;
}

export class CatalogStore {
  #snapshot;
  #query = "";
  #category = null;
  #page = 0;
  #pageSize;

  constructor(snapshot, { pageSize = DEFAULT_PAGE_SIZE } = {}) {
    assert(snapshot?.products && Array.isArray(snapshot.products), "catalog snapshot is required");
    this.#snapshot = snapshot;
    this.#pageSize = this.#validatedPageSize(pageSize);
  }

  get snapshot() {
    return this.#snapshot;
  }

  setQuery(query) {
    this.#query = normalizeText(query);
    this.#page = 0;
    return this.view();
  }

  setCategory(categoryId) {
    this.#category = categoryId ? normalizeText(categoryId) : null;
    this.#page = 0;
    return this.view();
  }

  setPageSize(pageSize) {
    const nextSize = this.#validatedPageSize(pageSize);
    const firstVisibleIndex = this.#page * this.#pageSize;
    this.#pageSize = nextSize;
    this.#page = Math.floor(firstVisibleIndex / nextSize);
    this.#clampPage();
    return this.view();
  }

  previous() {
    this.#page = Math.max(0, this.#page - 1);
    return this.view();
  }

  next() {
    this.#page = Math.min(this.#lastPageIndex(), this.#page + 1);
    return this.view();
  }

  home() {
    this.#page = 0;
    return this.view();
  }

  goTo(pageNumber) {
    const requested = Math.max(1, Number(pageNumber) || 1) - 1;
    this.#page = Math.min(this.#lastPageIndex(), requested);
    return this.view();
  }

  findProduct(productId) {
    return this.#snapshot.products.find((product) => product.id === productId) ?? null;
  }

  view() {
    this.#clampPage();
    const products = this.#filteredProducts();
    const pageCount = Math.max(1, Math.ceil(products.length / this.#pageSize));
    const start = this.#page * this.#pageSize;

    return immutable({
      snapshotId: this.#snapshot.id,
      products: products.slice(start, start + this.#pageSize),
      totalProducts: products.length,
      page: this.#page + 1,
      pageCount,
      pageSize: this.#pageSize,
      hasPrevious: this.#page > 0,
      hasNext: this.#page + 1 < pageCount,
      query: this.#query,
      category: this.#category
    });
  }

  #filteredProducts() {
    return this.#snapshot.products.filter((product) => {
      const categoryMatches = !this.#category || product.category.id === this.#category;
      const queryMatches = !this.#query || product.searchText.includes(this.#query);
      return categoryMatches && queryMatches;
    });
  }

  #lastPageIndex() {
    return Math.max(0, Math.ceil(this.#filteredProducts().length / this.#pageSize) - 1);
  }

  #clampPage() {
    this.#page = Math.min(this.#page, this.#lastPageIndex());
  }

  #validatedPageSize(value) {
    const pageSize = Number(value);
    assert(Number.isInteger(pageSize) && pageSize > 0, "page size must be a positive integer");
    return pageSize;
  }
}

export class CheckoutController {
  #gateway;
  #state = immutable({ status: "idle" });

  constructor(gateway) {
    assert(gateway && typeof gateway.quote === "function", "checkout gateway quote is required");
    assert(typeof gateway.accept === "function", "checkout gateway accept is required");
    assert(typeof gateway.refresh === "function", "checkout gateway refresh is required");
    this.#gateway = gateway;
  }

  get state() {
    return this.#state;
  }

  async quote(product) {
    this.#state = immutable({ status: "quoting", product });
    try {
      const quote = await this.#gateway.quote(product.id);
      this.#state = immutable({ status: "quoted", product, quote });
    } catch (error) {
      this.#state = immutable({ status: "failed", product, error: String(error.message ?? error) });
    }
    return this.#state;
  }

  async accept() {
    assert(this.#state.status === "quoted", "a quote must be loaded before acceptance");
    const { product, quote } = this.#state;
    this.#state = immutable({ status: "accepting", product, quote });
    try {
      const order = await this.#gateway.accept(quote.id);
      this.#state = immutable({ status: order.attributes.status, product, quote, order });
    } catch (error) {
      this.#state = immutable({ status: "failed", product, quote, error: String(error.message ?? error) });
    }
    return this.#state;
  }

  async refresh() {
    assert(this.#state.order?.id, "an order must exist before refresh");
    const { product, quote, order } = this.#state;
    try {
      const refreshed = await this.#gateway.refresh(order.id);
      this.#state = immutable({ status: refreshed.attributes.status, product, quote, order: refreshed });
    } catch (error) {
      this.#state = immutable({ status: "failed", product, quote, order, error: String(error.message ?? error) });
    }
    return this.#state;
  }
}

export function formatPrice(product) {
  const price = product?.attributes?.price;
  if (!price) return null;
  return `${price.amount} ${price.currency}`;
}
