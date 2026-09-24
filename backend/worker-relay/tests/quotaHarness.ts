import { QuotaDO, type QuotaEnvironment } from "../src/quota";

// Exercise the production DO handler with isolated, copy-on-read storage and
// serialized requests. This does not emulate the Cloudflare network runtime.
export function makeQuotaNamespace(failBudget: () => boolean = () => false) {
  const objects = new Map<string, QuotaDO>();
  const namespace = {
    idFromName: (name: string) => name,
    get: (id: string) => ({
      fetch: async (url: string, init?: RequestInit) => {
        if (id === "global:budget" && failBudget()) throw new Error("budget temporarily unavailable");
        let object = objects.get(id);
        if (!object) {
          const values = new Map<string, unknown>();
          let tail: Promise<unknown> = Promise.resolve();
          const state = {
            storage: {
              get: async (key: string) => structuredClone(values.get(key)),
              put: async (key: string, value: unknown) => { values.set(key, structuredClone(value)); },
            },
            blockConcurrencyWhile: <T>(callback: () => Promise<T>): Promise<T> => {
              const task = tail.then(callback);
              tail = task.catch(() => undefined);
              return task;
            },
          } as unknown as DurableObjectState;
          object = new QuotaDO(state, { QUOTA: namespace } as unknown as QuotaEnvironment);
          objects.set(id, object);
        }
        return object.fetch(new Request(url, init));
      },
    }),
  };
  return namespace as unknown as DurableObjectNamespace;
}
