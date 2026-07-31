import pg from "pg";
import { logger, errFields } from "./logger.js";

const { Pool } = pg;

/**
 * Two ways to configure a DB connection, both supported on purpose:
 *
 *  1. DATABASE_URL -- one connection string. What Heroku/Render/Fly/RDS hand
 *     you, and what most ORMs expect. Easy to inject as a single secret.
 *  2. Discrete PGHOST/PGUSER/... vars -- easier to compose in Docker Compose
 *     from the same values Postgres itself is configured with, and it avoids
 *     URL-encoding headaches when a password contains @ / : or #.
 *
 * We build (2) into (1) when (1) isn't given, so the rest of the app only ever
 * deals with one shape.
 */
function buildConnectionString() {
  if (process.env.DATABASE_URL) return process.env.DATABASE_URL;

  const host = required("POSTGRES_HOST");
  const port = process.env.POSTGRES_PORT ?? "5432";
  const user = required("POSTGRES_USER");
  const password = required("POSTGRES_PASSWORD");
  const database = required("POSTGRES_DB");

  return `postgres://${encodeURIComponent(user)}:${encodeURIComponent(password)}@${host}:${port}/${database}`;
}

function required(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

const connectionString = buildConnectionString();

export const pool = new Pool({
  connectionString,
  max: Number(process.env.DB_POOL_MAX ?? 10),
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
});

pool.on("error", (error) => {
  logger.error("Unexpected error on idle database client", errFields(error));
});

export function describeTarget() {
  const url = new URL(connectionString);
  return {
    host: url.hostname,
    port: url.port || "5432",
    database: url.pathname.slice(1),
    user: url.username,
  };
}

export async function pingDatabase() {
  const { rows } = await pool.query("SELECT 1 AS ok");
  return rows[0].ok === 1;
}

/**
 *
 * @param {object}  opts
 * @param {number}  opts.maxRetries  attempts before giving up
 * @param {number}  opts.delayMs     base delay between attempts
 * @returns {Promise<void>} resolves once the DB answered; throws if it never did
 */
export async function waitForDatabase({ maxRetries, delayMs }) {
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  const target = describeTarget();

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      await pingDatabase();
      logger.info("Database connection established", { attempt, ...target });
      return;
    } catch (error) {
      logger.warn("Database not ready", {
        attempt,
        maxRetries,
        ...target,
        ...errFields(error),
      });

      if (attempt === maxRetries) {
        throw new Error(
          `Database unreachable after ${maxRetries} attempts (${target.host}:${target.port}/${target.database})`,
          { cause: error },
        );
      }

      await sleep(delayMs);
    }
  }
}

/** Close the pool during graceful shutdown so Postgres reclaims connections. */
export async function closeDatabase() {
  await pool.end();
}
