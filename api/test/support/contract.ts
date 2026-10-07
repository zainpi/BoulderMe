// Checks every response the tests receive against docs/api/openapi.yaml: the status must be
// documented for that operation and the body must match its schema.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { parse } from "yaml";

const specPath = fileURLToPath(new URL("../../../docs/api/openapi.yaml", import.meta.url).href);
const spec = parse(readFileSync(specPath, "utf8"));

function rewriteRefs(node: unknown): unknown {
  if (Array.isArray(node)) return node.map(rewriteRefs);
  if (node && typeof node === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(node)) {
      out[k] = k === "$ref" && typeof v === "string" && v.startsWith("#/") ? `openapi${v}` : rewriteRefs(v);
    }
    return out;
  }
  return node;
}

const ajv = new Ajv2020({ strict: false, allErrors: true });
(addFormats as unknown as (a: Ajv2020) => void)(ajv);
ajv.addSchema({ $id: "openapi", components: rewriteRefs(spec.components) });

const operations = Object.entries(spec.paths as Record<string, Record<string, any>>).map(([path, item]) => ({
  regex: new RegExp(`^${path.replace(/\{\w+\}/g, "[^/]+")}$`),
  item,
}));

const validators = new WeakMap<object, ReturnType<typeof ajv.compile>>();

function resolveResponse(response: any): any {
  if (response?.$ref) {
    const name = String(response.$ref).split("/").pop()!;
    return spec.components.responses[name];
  }
  return response;
}

/** Throws with a readable message when the response breaks the contract. */
export function assertMatchesContract(method: string, pathname: string, status: number, body: unknown): void {
  const op = operations.find((o) => o.regex.test(pathname))?.item[method.toLowerCase()];
  if (!op) {
    // Unknown routes must use the Error envelope with not_found.
    if (status !== 404) throw new Error(`${method} ${pathname}: undocumented route returned ${status}`);
    validate(ERROR_SCHEMA, body, `${method} ${pathname}`);
    return;
  }
  // The spec's description makes 429, 500 and 503 (Error envelope) valid on every route.
  const global = [429, 500, 503].includes(status) ? spec.components.responses.Unavailable : undefined;
  const response = resolveResponse(op.responses[String(status)]) ?? global;
  if (!response) {
    throw new Error(`${method} ${pathname}: status ${status} is not documented in openapi.yaml`);
  }
  const schema = response.content?.["application/json"]?.schema;
  if (!schema) {
    if (body !== null) throw new Error(`${method} ${pathname}: ${status} must have no body`);
    return;
  }
  validate(schema, body, `${method} ${pathname} ${status}`);
}

const ERROR_SCHEMA = { $ref: "#/components/schemas/Error" };

function validate(schema: object, body: unknown, label: string): void {
  let v = validators.get(schema);
  if (!v) {
    v = ajv.compile(rewriteRefs(schema) as object);
    validators.set(schema, v);
  }
  if (!v(body)) {
    throw new Error(`${label}: response does not match openapi.yaml\n${JSON.stringify(v.errors, null, 2)}\n${JSON.stringify(body, null, 2)}`);
  }
}
