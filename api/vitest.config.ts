import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    // Postgres-backed suites share one database; run files one at a time.
    fileParallelism: false,
    testTimeout: 15000,
  },
});
