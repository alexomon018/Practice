const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };
const activeLevel = LEVELS[process.env.LOG_LEVEL ?? "info"] ?? LEVELS.info;
const service = process.env.SERVICE_NAME ?? "backend";

function emit(level, message, context = {}) {
  if (LEVELS[level] < activeLevel) return;

  const entry = {
    ts: new Date().toISOString(),
    level,
    service,
    message,
    ...context,
  };

  const line = JSON.stringify(entry);

  if (level === "warn" || level === "error") process.stderr.write(line + "\n");
  else process.stdout.write(line + "\n");
}

export function errFields(error) {
  if (!(error instanceof Error)) return { error: String(error) };
  return {
    error: error.message,
    errorName: error.name,
    errorCode: error.code,
    stack: error.stack,
  };
}

export const logger = {
  debug: (msg, ctx) => emit("debug", msg, ctx),
  info: (msg, ctx) => emit("info", msg, ctx),
  warn: (msg, ctx) => emit("warn", msg, ctx),
  error: (msg, ctx) => emit("error", msg, ctx),
};
