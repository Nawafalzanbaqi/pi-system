// content-admin (Directus) — minimal, env-driven content client for "__PROJECT_NAME__".
// =============================================================================
// SERVER-SIDE ONLY. Call these from Server Components, route handlers or server
// actions and pass the result down as props. The CMS runs on the internal Docker
// network with NO public port, so the browser can never reach it directly — the
// content is fetched on the server.
//
// No external dependencies: this uses the built-in `fetch` (Node 18+ / Next 15),
// so nothing is added to package.json. Prefer axios? `npm i axios` and reimplement
// `directusFetch` with it — the helpers below stay the same.
//
// The base URL defaults to the CMS service on the internal network (the service
// name is stamped in by the generator). Override it with the DIRECTUS_URL env var
// if needed. An optional DIRECTUS_TOKEN (a Directus static access token) is sent
// as a Bearer header when set; if your content collections grant read access to
// the Public role in /admin, NO token is required (the simplest setup).
//
// See templates/modules/content-admin/README.md for the suggested data model and
// how to add the env vars / token.
// =============================================================================

const DIRECTUS_URL = (process.env.DIRECTUS_URL || 'http://__PROJECT_NAME__-cms:8055').replace(/\/+$/, '');
const DIRECTUS_TOKEN = process.env.DIRECTUS_TOKEN || '';

// Seconds to cache content. 0 (default) => always fresh (no-store). Raise it
// (e.g. DIRECTUS_REVALIDATE=60) once content is stable to lighten the CMS.
const DEFAULT_REVALIDATE = Number(process.env.DIRECTUS_REVALIDATE || 0);

// Serialize a params object into a Directus query string. Nested objects become
// bracket syntax, so { filter: { slug: { _eq: 'about' } } } -> filter[slug][_eq]=about.
function buildQuery(params = {}) {
  const usp = new URLSearchParams();
  const add = (key, value) => {
    if (value === undefined || value === null) return;
    if (Array.isArray(value)) { usp.append(key, value.join(',')); return; }
    if (typeof value === 'object') {
      for (const [k, v] of Object.entries(value)) add(`${key}[${k}]`, v);
      return;
    }
    usp.append(key, String(value));
  };
  for (const [key, value] of Object.entries(params)) add(key, value);
  const qs = usp.toString();
  return qs ? `?${qs}` : '';
}

// Low-level GET against the Directus REST API. Returns the unwrapped `data`
// payload, or null on any failure — it never throws, so a page still renders if
// the CMS is still booting or a collection does not exist yet.
export async function directusFetch(path, { params, revalidate } = {}) {
  const url = `${DIRECTUS_URL}${path}${buildQuery(params)}`;
  const headers = { Accept: 'application/json' };
  if (DIRECTUS_TOKEN) headers.Authorization = `Bearer ${DIRECTUS_TOKEN}`;
  const rev = revalidate ?? DEFAULT_REVALIDATE;
  try {
    const res = await fetch(url, {
      headers,
      cache: rev > 0 ? undefined : 'no-store',
      next: rev > 0 ? { revalidate: rev } : undefined,
    });
    if (!res.ok) {
      console.error(`[directus] ${res.status} ${res.statusText} for ${path}`);
      return null;
    }
    const json = await res.json();
    return json?.data ?? null;
  } catch (err) {
    console.error(`[directus] request failed for ${path}: ${err}`);
    return null;
  }
}

// --- Generic collection helpers ----------------------------------------------
export async function getItems(collection, params = {}, opts = {}) {
  const data = await directusFetch(`/items/${collection}`, { params, ...opts });
  return Array.isArray(data) ? data : [];
}

export async function getItemById(collection, id, params = {}, opts = {}) {
  return directusFetch(`/items/${collection}/${encodeURIComponent(id)}`, { params, ...opts });
}

// A Directus "singleton" collection (e.g. settings) returns an object, not a list.
export async function getSingleton(collection, params = {}, opts = {}) {
  return directusFetch(`/items/${collection}`, { params, ...opts });
}

// Fetch one item by a unique field (e.g. a URL slug).
export async function getItemByField(collection, field, value, params = {}, opts = {}) {
  const rows = await getItems(collection, { filter: { [field]: { _eq: value } }, limit: 1, ...params }, opts);
  return rows[0] ?? null;
}

// --- Suggested content model (see the module README) -------------------------
// Thin conveniences over the generic helpers, matching the suggested,
// frontend-agnostic collections: `pages`, `posts`, a `navigation` list and a
// `settings` singleton. Rename/extend these to match the collections you build
// in /admin. Item helpers filter to published rows (assuming a `status` field).
const PUBLISHED = { status: { _eq: 'published' } };

export function getPages(params = {}, opts = {}) {
  return getItems('pages', { filter: PUBLISHED, sort: 'sort', fields: '*', ...params }, opts);
}
export async function getPage(slug, params = {}, opts = {}) {
  const rows = await getItems('pages', { filter: { ...PUBLISHED, slug: { _eq: slug } }, limit: 1, fields: '*', ...params }, opts);
  return rows[0] ?? null;
}
export function getPosts(params = {}, opts = {}) {
  return getItems('posts', { filter: PUBLISHED, sort: '-date_published', fields: '*', ...params }, opts);
}
export async function getPost(slug, params = {}, opts = {}) {
  const rows = await getItems('posts', { filter: { ...PUBLISHED, slug: { _eq: slug } }, limit: 1, fields: '*', ...params }, opts);
  return rows[0] ?? null;
}
export function getNavigation(params = {}, opts = {}) {
  return getItems('navigation', { sort: 'sort', fields: '*', ...params }, opts);
}
export function getSettings(params = {}, opts = {}) {
  return getSingleton('settings', { fields: '*', ...params }, opts);
}

// The resolved internal base URL (handy for building asset URLs server-side:
// `${directusUrl}/assets/<file-id>`).
export const directusUrl = DIRECTUS_URL;
