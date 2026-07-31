import express from "express";
import { pool, pingDatabase, describeTarget } from "./db.js";
import { logger, errFields } from "./logger.js";

export const router = express.Router();

router.get("/health", (req, res) => {
  res.json({ status: "ok", uptimeSeconds: Math.round(process.uptime()) });
});

router.get("/ready", async (req, res) => {
  try {
    await pingDatabase();
    res.json({ status: "ready", database: "up" });
  } catch (error) {
    logger.warn("Readiness check failed", errFields(error));
    res.status(503).json({ status: "not-ready", database: "down" });
  }
});

router.get("/info", (req, res) => {
  res.json({
    service: process.env.SERVICE_NAME ?? "backend",
    nodeEnv: process.env.NODE_ENV ?? "development",
    logLevel: process.env.LOG_LEVEL ?? "info",
    servedBy: process.env.HOSTNAME ?? "unknown",
    database: describeTarget(),
  });
});

router.get("/items", async (req, res, next) => {
  try {
    const { rows } = await pool.query(
      "SELECT id, name, description, price_cents, created_at FROM items ORDER BY created_at DESC, id DESC",
    );
    logger.debug("Listed items", { count: rows.length });
    res.json({ items: rows });
  } catch (error) {
    next(error);
  }
});

router.post("/items", async (req, res, next) => {
  try {
    const { name, description, priceCents } = req.body ?? {};

    if (typeof name !== "string" || name.trim().length === 0) {
      return res.status(400).json({ error: "name is required" });
    }

    // Parameterised query ($1, $2, ...) -- the driver sends values separately
    // from the SQL text, so string concatenation SQL injection is impossible.
    const { rows } = await pool.query(
      `INSERT INTO items (name, description, price_cents)
       VALUES ($1, $2, $3)
       RETURNING id, name, description, price_cents, created_at`,
      [
        name.trim(),
        (description ?? "").trim() || null,
        Number.isFinite(Number(priceCents)) ? Number(priceCents) : 0,
      ],
    );

    logger.info("Item created", { itemId: rows[0].id, name: rows[0].name });
    res.status(201).json({ item: rows[0] });
  } catch (error) {
    next(error);
  }
});

router.delete("/items/:id", async (req, res, next) => {
  try {
    const { rowCount } = await pool.query("DELETE FROM items WHERE id = $1", [
      req.params.id,
    ]);
    if (rowCount === 0)
      return res.status(404).json({ error: "item not found" });

    logger.info("Item deleted", { itemId: req.params.id });
    res.status(204).end();
  } catch (error) {
    next(error);
  }
});
