import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { StringEnum, Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const MAX_HOST_OUTPUT = 96 * 1024;
const HOST_TIMEOUT_MS = 135_000;
const extensionRoot = dirname(fileURLToPath(import.meta.url));
const hostPath = join(extensionRoot, "lib", "worker_host.py");

function pythonPath(): string | undefined {
  const candidates = [
    process.env.SKEIN_PI_PYTHON,
    "/usr/bin/python3",
    "/opt/homebrew/bin/python3",
    "/usr/local/bin/python3",
  ];
  for (const candidate of candidates) {
    if (candidate && isAbsolute(candidate) && existsSync(candidate)) return realpathSync(candidate);
  }
  return undefined;
}

function killGroup(child: ReturnType<typeof spawn>) {
  if (!child.pid) return;
  try {
    process.kill(-child.pid, "SIGTERM");
  } catch {}
  setTimeout(() => {
    try {
      process.kill(-child.pid!, "SIGKILL");
    } catch {}
  }, 300).unref();
}

async function runHost(request: unknown, credential: string, signal: AbortSignal | undefined) {
  const python = pythonPath();
  const piCli = process.argv[1];
  if (!python || !piCli || !isAbsolute(piCli) || !existsSync(piCli) || !existsSync(hostPath)) {
    throw new Error("runtime_unavailable");
  }
  const child = spawn(python, [hostPath], {
    cwd: (request as { cwd: string }).cwd,
    detached: true,
    env: {
      PATH: "/usr/bin:/bin",
      LANG: "C.UTF-8",
      PYTHONNOUSERSITE: "1",
      PYTHONDONTWRITEBYTECODE: "1",
    },
    stdio: ["pipe", "pipe", "pipe", "pipe"],
  });
  let stdout = Buffer.alloc(0);
  let bytes = 0;
  let overflow = false;
  const onData = (chunk: Buffer, keep: boolean) => {
    bytes += chunk.length;
    if (bytes > MAX_HOST_OUTPUT) {
      overflow = true;
      killGroup(child);
      return;
    }
    if (keep) stdout = Buffer.concat([stdout, chunk]);
  };
  child.stdout.on("data", (chunk: Buffer) => onData(chunk, true));
  child.stderr.on("data", (chunk: Buffer) => onData(chunk, false));
  const secretPipe = child.stdio[3];
  if (!secretPipe || !("end" in secretPipe)) {
    killGroup(child);
    throw new Error("credential_channel_unavailable");
  }
  const abort = () => killGroup(child);
  signal?.addEventListener("abort", abort, { once: true });
  const timer = setTimeout(() => killGroup(child), HOST_TIMEOUT_MS);
  child.stdin.end(JSON.stringify(request));
  (secretPipe as NodeJS.WritableStream).end(credential);
  const exitCode = await new Promise<number | null>((resolve, reject) => {
    child.once("error", reject);
    child.once("close", resolve);
  }).finally(() => {
    clearTimeout(timer);
    signal?.removeEventListener("abort", abort);
  });
  if (signal?.aborted) throw new Error("operator_cancelled");
  if (overflow) throw new Error("host_output_limit");
  if (exitCode !== 0) throw new Error("host_failed");
  if (stdout.length === 0 || stdout.length > MAX_HOST_OUTPUT) throw new Error("host_output_invalid");
  const lines = stdout.toString("utf8").trimEnd().split("\n");
  if (lines.length !== 1) throw new Error("host_output_invalid");
  const value = JSON.parse(lines[0]);
  if (!value || value.schema_version !== 1 || typeof value.status !== "string") {
    throw new Error("host_output_invalid");
  }
  return value;
}

async function selection(ctx: ExtensionContext, role: string, prompt: string) {
  const model = ctx.model;
  if (!model) throw new Error("no_selected_model");
  if (model.api !== "openai-completions") throw new Error("model_api_unsupported");
  if (ctx.modelRegistry.isUsingOAuth(model)) throw new Error("oauth_unsupported");
  const status = ctx.modelRegistry.getProviderAuthStatus(model.provider);
  if (!status.configured || status.source === "models_json_command" || status.source === "fallback") {
    throw new Error("credential_source_unsupported");
  }
  const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
  if (!auth.ok || !auth.apiKey || auth.headers || auth.env) throw new Error("credential_shape_unsupported");
  const baseUrl = auth.baseUrl ?? model.baseUrl;
  if (!baseUrl) throw new Error("endpoint_unavailable");
  if (!ctx.hasUI) throw new Error("operator_confirmation_unavailable");
  const approved = await ctx.ui.confirm(
    "Approve isolated Skein worker?",
    `Role: ${role}\nExact task JSON string: ${JSON.stringify(prompt)}\n\nModel: ${model.provider}/${model.id}\nEndpoint: ${baseUrl}\nCredential source: ${status.source ?? "unknown"}\nChild thinking: off; tools: none`,
    { signal: ctx.signal },
  );
  if (!approved) throw new Error("operator_declined");
  return {
    credential: auth.apiKey,
    approval: {
      approved: true,
      provider: model.provider,
      model: model.id,
      api: model.api,
      base_url: baseUrl,
      thinking: "off",
      context_window: model.contextWindow,
      max_tokens: model.maxTokens,
      credential_type: "api_key",
    },
  };
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "skein_worker",
    label: "Skein isolated worker",
    description: "Run one bounded fresh-context factual, mechanical, or judgment task. Requires explicit user approval; no tools or ambient project context enter the worker.",
    parameters: Type.Object(
      {
        role: StringEnum(["factual", "mechanical", "judgment"] as const),
        prompt: Type.String({ minLength: 1, maxLength: 131072 }),
      },
      { additionalProperties: false },
    ),
    executionMode: "sequential",
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      try {
        const selected = await selection(ctx, params.role, params.prompt);
        const taskId = `worker-${randomBytes(12).toString("hex")}`;
        const request = {
          approval: selected.approval,
          node: realpathSync(process.execPath),
          pi_cli: realpathSync(process.argv[1]),
          cwd: realpathSync(ctx.cwd),
          temp_root: realpathSync(tmpdir()),
          state_root: join(realpathSync(ctx.cwd), ".skein-pi-attempts"),
          project_rules: "",
          task: { task_id: taskId, attempt: 1, role: params.role, prompt: params.prompt },
          timeout_s: 120,
          output_limit: 4 * 1024 * 1024,
        };
        const result = await runHost(request, selected.credential, signal);
        if (result.status !== "completed") {
          const status = typeof result.status === "string" && /^[a-z_]+$/.test(result.status)
            ? result.status
            : "invalid_output";
          throw new Error(`worker_${status}`);
        }
        return {
          content: [{ type: "text" as const, text: JSON.stringify(result) }],
          details: result,
        };
      } catch (error) {
        const reason = error instanceof Error && /^[a-z_]+$/.test(error.message) ? error.message : "host_unavailable";
        throw new Error(`Skein worker unavailable: ${reason}. No worker result was accepted.`);
      }
    },
  });
}
