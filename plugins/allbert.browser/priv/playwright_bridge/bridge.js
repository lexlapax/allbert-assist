"use strict";

const readline = require("node:readline");
const {Buffer} = require("node:buffer");
const playwrightPackage = require("playwright/package.json");
const {chromium} = require("playwright");

const sessions = new Map();
let browser = null;

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity
});

rl.on("line", async (line) => {
  if (!line.trim()) {
    return;
  }

  let request;

  try {
    request = JSON.parse(line);
  } catch (error) {
    respond(null, false, null, {kind: "invalid_json", message: error.message});
    return;
  }

  try {
    const result = await dispatch(request.op, request.params || {});
    respond(request.id, true, result, null);
  } catch (error) {
    respond(request.id, false, null, normalizeError(error));
  }
});

process.on("SIGTERM", async () => {
  await shutdown();
  process.exit(0);
});

process.on("SIGINT", async () => {
  await shutdown();
  process.exit(0);
});

async function dispatch(op, params) {
  switch (op) {
    case "verify":
      return verify(params);
    case "start_session":
      return startSession(params);
    case "navigate":
      return navigate(params);
    case "extract":
      return extract(params);
    case "screenshot":
      return screenshot(params);
    case "click":
      return click(params);
    case "fill":
      return fill(params);
    case "download":
      return download(params);
    case "close_session":
      return closeSession(params);
    case "shutdown":
      await shutdown();
      return {closed: true};
    default:
      throw bridgeError("unsupported_operation", `Unsupported bridge operation: ${op}`);
  }
}

async function verify(params) {
  const probeBrowser = await launchBrowser(params);
  const context = await probeBrowser.newContext(contextOptions(params));
  const page = await context.newPage();

  try {
    await page.goto("about:blank", gotoOptions(params));

    return {
      driver: "playwright",
      browser: "chromium",
      playwright_version: playwrightPackage.version,
      live_check_status: "ok",
      capabilities: ["navigate", "extract", "screenshot", "click", "fill", "download"]
    };
  } finally {
    await safeClose(context);
    await safeClose(probeBrowser);
  }
}

async function startSession(params) {
  const sessionId = requireParam(params, "session_id");
  await ensureBrowser(params);
  const context = await browser.newContext(contextOptions(params));
  const page = await context.newPage();

  sessions.set(sessionId, {context, page, lastUrl: null});

  return {
    session_id: sessionId,
    browser: "chromium",
    playwright_version: playwrightPackage.version
  };
}

async function navigate(params) {
  const session = sessionFor(params);
  const response = await session.page.goto(requireParam(params, "url"), gotoOptions(params));
  const title = await session.page.title().catch(() => "");
  session.lastUrl = session.page.url();

  return {
    url: session.page.url(),
    title,
    status: response ? response.status() : null,
    redirected_to: session.page.url() === params.url ? null : session.page.url()
  };
}

async function extract(params) {
  const session = sessionFor(params);
  const format = params.format || "text";
  const maxBytes = params.max_bytes || 1048576;
  let content;

  if (format === "html" || format === "markdown") {
    content = await session.page.content();
  } else {
    content = await session.page.evaluate(() => document.body ? document.body.innerText || "" : "");
  }

  const bounded = boundUtf8(content, maxBytes);

  return {
    format,
    content: bounded.content,
    text: bounded.content,
    bytes: Buffer.byteLength(bounded.content, "utf8"),
    truncated: bounded.truncated
  };
}

async function screenshot(params) {
  const session = sessionFor(params);

  if (params.redact_credential_inputs !== false) {
    await session.page.evaluate(() => {
      const selector = [
        "input[type=password]",
        "input[autocomplete=otp]",
        "input[autocomplete=cc-number]",
        "input[name*=password i]",
        "input[name*=token i]",
        "input[name*=secret i]"
      ].join(",");

      document.querySelectorAll(selector).forEach((input) => {
        input.setAttribute("value", "[REDACTED]");
        input.value = "[REDACTED]";
      });
    }).catch(() => null);
  }

  const buffer = await session.page.screenshot({
    fullPage: params.full_page === true,
    type: "png"
  });

  const maxBytes = params.max_bytes || 524288;

  if (buffer.length > maxBytes) {
    throw bridgeError("screenshot_too_large", `Screenshot exceeded ${maxBytes} bytes`);
  }

  return {
    content_base64: buffer.toString("base64"),
    bytes: buffer.length,
    redacted_credential_inputs: params.redact_credential_inputs !== false
  };
}

async function click(params) {
  const session = sessionFor(params);
  const selector = requireParam(params, "selector");
  const locator = session.page.locator(selector).first();
  const visibleLabel = params.visible_label_preview || await locator.textContent({timeout: params.timeout_ms || 30000}).catch(() => "");
  await locator.click({timeout: params.timeout_ms || 30000});

  return {
    selector,
    visible_label_preview: visibleLabel || "",
    navigation_triggered: false,
    url: session.page.url()
  };
}

async function fill(params) {
  const session = sessionFor(params);
  const selector = requireParam(params, "selector");
  const value = params.value || "";
  await session.page.locator(selector).first().fill(value, {timeout: params.timeout_ms || 30000});

  return {
    selector,
    value_preview: params.value_preview || "[REDACTED]",
    value_redacted: true,
    url: session.page.url()
  };
}

async function download(params) {
  const session = sessionFor(params);
  const url = requireParam(params, "url");

  const downloadPromise = session.page.waitForEvent("download", {timeout: params.timeout_ms || 30000});
  await session.page.goto(url, gotoOptions(params));
  const download = await downloadPromise;
  const path = await download.path();

  return {
    url,
    filename: params.filename || download.suggestedFilename(),
    path,
    persisted: false
  };
}

async function closeSession(params) {
  const sessionId = requireParam(params, "session_id");
  const session = sessions.get(sessionId);

  if (session) {
    sessions.delete(sessionId);
    await safeClose(session.context);
  }

  if (sessions.size === 0) {
    await safeClose(browser);
    browser = null;
  }

  return {session_id: sessionId, closed: true};
}

async function ensureBrowser(params) {
  if (!browser || !browser.isConnected()) {
    browser = await launchBrowser(params);
  }
}

async function launchBrowser(params) {
  const options = {headless: true};

  if (params.executable_path) {
    options.executablePath = params.executable_path;
  }

  const args = [];

  if (params.host_resolver_rules) {
    args.push(`--host-resolver-rules=${params.host_resolver_rules}`);
  }

  if (args.length > 0) {
    options.args = args;
  }

  if (params.timeout_ms) {
    options.timeout = params.timeout_ms;
  }

  return chromium.launch(options);
}

function contextOptions(params) {
  const options = {
    acceptDownloads: true,
    javaScriptEnabled: params.javascript_enabled !== false
  };

  if (params.user_agent) {
    options.userAgent = params.user_agent;
  }

  return options;
}

function gotoOptions(params) {
  return {
    waitUntil: params.wait_until || "domcontentloaded",
    timeout: params.timeout_ms || 30000
  };
}

async function shutdown() {
  for (const session of sessions.values()) {
    await safeClose(session.context);
  }

  sessions.clear();
  await safeClose(browser);
  browser = null;
}

async function safeClose(resource) {
  if (!resource) {
    return;
  }

  try {
    await resource.close();
  } catch (_error) {
    // Closing is best-effort during cleanup.
  }
}

function sessionFor(params) {
  const sessionId = requireParam(params, "session_id");
  const session = sessions.get(sessionId);

  if (!session) {
    throw bridgeError("session_not_found", `Unknown session: ${sessionId}`);
  }

  return session;
}

function requireParam(params, key) {
  const value = params[key];

  if (value === undefined || value === null || value === "") {
    throw bridgeError("missing_param", `Missing required parameter: ${key}`);
  }

  return value;
}

function boundUtf8(content, maxBytes) {
  let output = String(content || "");

  if (Buffer.byteLength(output, "utf8") <= maxBytes) {
    return {content: output, truncated: false};
  }

  while (Buffer.byteLength(output, "utf8") > maxBytes) {
    output = output.slice(0, -1);
  }

  return {content: output, truncated: true};
}

function respond(id, ok, result, error) {
  const payload = ok ? {id, ok, result} : {id, ok, error};
  process.stdout.write(`${JSON.stringify(payload)}\n`);
}

function normalizeError(error) {
  return {
    kind: error.kind || "playwright_error",
    message: error.message || String(error)
  };
}

function bridgeError(kind, message) {
  const error = new Error(message);
  error.kind = kind;
  return error;
}
