#!/usr/bin/env node
// Dump the current pi session into agent-history/harness-sessions/.
//   machine-readable/<uuid>.jsonl                       raw session JSONL (verbatim copy)
//   human-readable/<name>--pi-session-<uuid-stem>.md    conversation-only markdown
//
// Usage: node dump-session.mjs [options] [name]
//   --name <name>   Override session name (default: /name-set name, else "session")
//   --out <dir>     Output root (default: <cwd>/agent-history/harness-sessions)
//   --quiet         Only print the two output paths

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

// ---- args ------------------------------------------------------------------
const argv = process.argv.slice(2);
let nameArg = null;
let outArg = null;
let quiet = false;
const positional = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--name") nameArg = argv[++i];
  else if (argv[i] === "--out") outArg = argv[++i];
  else if (argv[i] === "--quiet") quiet = true;
  else positional.push(argv[i]);
}

const cwd = process.cwd();

// ---- locate the session JSONL ----------------------------------------------
function findSessionFile() {
  // 1. Pi injects PI_SESSION_FILE into every shell command it runs.
  if (process.env.PI_SESSION_FILE && fs.existsSync(process.env.PI_SESSION_FILE)) {
    return process.env.PI_SESSION_FILE;
  }
  // 2. Fallback: newest JSONL in the cwd bucket under the pi session dir.
  const agentDir =
    process.env.PI_CODING_AGENT_DIR || path.join(os.homedir(), ".pi", "agent");
  const bucket = `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
  const dir = path.join(agentDir, "sessions", bucket);
  if (!fs.existsSync(dir)) return null;
  const candidates = fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".jsonl"))
    .map((f) => {
      const p = path.join(dir, f);
      return { p, m: fs.statSync(p).mtimeMs };
    })
    .sort((a, b) => b.m - a.m);
  // Prefer a file whose header cwd matches; otherwise newest wins.
  for (const c of candidates) {
    try {
      const first = fs.readFileSync(c.p, "utf8").split("\n", 1)[0];
      if (JSON.parse(first).cwd === cwd) return c.p;
    } catch {}
  }
  return candidates[0]?.p ?? null;
}

const sessionFile = findSessionFile();
if (!sessionFile) {
  console.error("error: could not locate the current session JSONL");
  process.exit(1);
}

const raw = fs.readFileSync(sessionFile, "utf8");
const entries = raw
  .split("\n")
  .filter((l) => l.trim())
  .map((l) => {
    try {
      return JSON.parse(l);
    } catch {
      return null;
    }
  })
  .filter(Boolean);

// ---- session name & timestamp ----------------------------------------------
const header = entries.find((e) => e.type === "session");
const name =
  nameArg ??
  positional[0] ??
  [...entries].reverse().find((e) => e.type === "session_info" && e.name)?.name ??
  "session";
const safeName = String(name).replace(/[^\w.-]+/g, "-").replace(/^-+|-+$/g, "") || "session";

const startTs =
  header?.timestamp ?? sessionFile.match(/(\d{4}-\d{2}-\d{2}T[\d-]+Z?)/)?.[1] ?? new Date().toISOString();
const ts = startTs.replace(/[:.]/g, "-").replace(/Z$/, "");

// ---- active branch (walk parentId chain from leaf) --------------------------
const byId = new Map(entries.map((e) => [e.id, e]));
let leaf = entries[entries.length - 1];
for (let i = entries.length - 1; i >= 0; i--) {
  if (entries[i].type === "message") {
    leaf = entries[i];
    break;
  }
}
const branch = [];
for (let e = leaf; e; e = e.parentId ? byId.get(e.parentId) : undefined) branch.unshift(e);

// ---- human-readable rendering ----------------------------------------------
function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((b) => b.type === "text")
    .map((b) => b.text)
    .join("\n");
}

const mdParts = [
  `# Session dump: ${name}`,
  "",
  `- **Session id:** ${header?.id ?? path.basename(sessionFile, ".jsonl")}`,
  `- **Started:** ${startTs}`,
  `- **Source:** \`${sessionFile}\``,
  `- **Machine-readable copy:** \`${path.basename(sessionFile)}\` (in ../machine-readable/)`,
  "",
  "---",
];

let toolCount = 0;
for (const e of branch) {
  if (e.type === "session_info") {
    mdParts.push("", `> ✏️ session renamed to **${e.name}**`, "");
  } else if (e.type === "compaction") {
    mdParts.push("", "> 🗜️ *(older context compacted/summarized here)*", "");
  } else if (e.type === "message") {
    const role = e.message?.role;
    if (role === "user") {
      const t = textOf(e.message.content).trim();
      if (t) mdParts.push("", "## 🧑 User", "", t, "");
    } else if (role === "assistant") {
      const t = textOf(e.message.content).trim();
      for (const b of e.message.content ?? []) {
        if (b.type === "toolCall" || b.type === "tool_use") {
          toolCount++;
          mdParts.push(`> 🔧 \`${b.name ?? b.toolName ?? "tool"}\``);
        }
      }
      if (t) mdParts.push("", "## 🤖 Assistant", "", t, "");
    }
    // toolResult messages are skipped: noise for humans, preserved in the JSONL.
  }
}

// ---- write outputs ----------------------------------------------------------
const outRoot = outArg ?? path.join(cwd, "agent-history", "harness-sessions");
const machineDir = path.join(outRoot, "machine-readable");
const humanDir = path.join(outRoot, "human-readable");
fs.mkdirSync(machineDir, { recursive: true });
fs.mkdirSync(humanDir, { recursive: true });

const stem = path.basename(sessionFile).replace(/\.jsonl$/, "");
const machinePath = path.join(machineDir, `${stem}.jsonl`);
const humanPath = path.join(humanDir, `${safeName}--pi-session-${stem}.md`);

fs.writeFileSync(machinePath, raw);
fs.writeFileSync(humanPath, mdParts.join("\n") + "\n");

if (quiet) {
  console.log(machinePath);
  console.log(humanPath);
} else {
  const msgs = branch.filter((e) => e.type === "message").length;
  console.log(`session: ${name} (${header?.id ?? "?"}), ${msgs} messages on branch, ${toolCount} tool calls`);
  console.log(`machine: ${machinePath}`);
  console.log(`human:   ${humanPath}`);
}
