import express from "express";
import { randomUUID } from "node:crypto";

import { logger, errFields } from "./logger.js";
import { router } from "./routes.js";
import { waitForDatabase, closeDatabase, describeTarget } from "./db.js";

const PORT = Number(process.env.PORT ?? 3000);

// CRITICAL for containers: bind 0.0.0.0, never 127.0.0.1.
const HOST = process.env.HOST ?? "0.0.0.0";

const app = express();

app.set("trust proxy", true);

app.use(express.json({ limit: "100kb" }));

app.use((req, res, next) => {
  const requestId = req.headers["x-request-id"] ?? randomUUID();
  const startedAt = process.hrtime.bigint();

  res.setHeader("X-Request-Id", requestId);
  req.requestId = requestId;

  res.on("finish", () => {
    const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    const level =
      res.statusCode >= 500 ? "error" : res.statusCode >= 400 ? "warn" : "info";

    logger[level]("http_request", {
      requestId,
      method: req.method,
      path: req.originalUrl,
      status: res.statusCode,
      durationMs: Number(durationMs.toFixed(2)),
      // Thanks to `trust proxy`, this is the real browser IP from
      // X-Forwarded-For rather than the nginx container's address.
      ip: req.ip,
      userAgent: req.headers["user-agent"],
    });
  });

  next();
});

app.use("/api", router);

app.use((req, res) => {
  res.status(404).json({ error: "not found", path: req.originalUrl });
});

app.use((error, req, res, next) => {
  logger.error("Unhandled request error", {
    requestId: req.requestId,
    path: req.originalUrl,
    ...errFields(error),
  });
  res
    .status(500)
    .json({ error: "internal server error", requestId: req.requestId });
});

async function main() {
  logger.info("Backend starting", {
    nodeEnv: process.env.NODE_ENV,
    port: PORT,
    database: describeTarget(),
  });

  await waitForDatabase({
    maxRetries: Number(process.env.DB_CONNECT_MAX_RETRIES ?? 10),
    delayMs: Number(process.env.DB_CONNECT_RETRY_DELAY_MS ?? 1000),
  });

  const server = app.listen(PORT, HOST, () => {
    logger.info("Backend listening", { host: HOST, port: PORT });
  });

  const shutdown = async (signal) => {
    logger.info("Shutdown signal received", { signal });

    server.close(async () => {
      try {
        await closeDatabase();
        logger.info("Shutdown complete");
        process.exit(0);
      } catch (error) {
        logger.error("Error during shutdown", errFields(error));
        process.exit(1);
      }
    });

    setTimeout(() => {
      logger.warn("Forced exit after shutdown timeout");
      process.exit(1);
    }, 8000).unref();
  };

  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

main().catch((error) => {
  logger.error("Fatal error during startup", errFields(error));

  process.exit(1);
});
