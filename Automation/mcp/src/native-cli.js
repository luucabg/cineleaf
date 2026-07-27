import { spawn } from "node:child_process";
import { stat } from "node:fs/promises";
import path from "node:path";

export class NativeCliAdapter {
  constructor({ executable, prefixArguments = [] } = {}) {
    this.executable = executable ?? locateCli();
    this.prefixArguments = prefixArguments;
    this.inspectionCache = new Map();
  }

  async inspectMedia(mediaPath, signal) {
    let key;
    try {
      const metadata = await stat(mediaPath);
      key = `${path.resolve(mediaPath)}|${metadata.size}|${metadata.mtimeMs}`;
      if (this.inspectionCache.has(key)) return this.inspectionCache.get(key);
    } catch { /* the native bridge returns the authoritative missing-file error */ }
    const result = await this.#run(["inspect-media", mediaPath], signal);
    if (key) {
      this.inspectionCache.set(key, result);
      while (this.inspectionCache.size > 512) this.inspectionCache.delete(this.inspectionCache.keys().next().value);
    }
    return result;
  }

  async validateProject(projectPath, signal) {
    return this.#run(["validate-project", projectPath], signal);
  }

  async renderProject(projectPath, outputPath, options, signal, onProgress) {
    return this.#run(["render-project", projectPath, outputPath, options.resolution, options.codec, options.quality], signal, onProgress);
  }

  async extractAudio(inputPath, outputPath, options, signal) {
    return this.#run([
      "extract-audio", inputPath, outputPath,
      String(options.startSeconds ?? 0),
      options.durationSeconds == null ? "all" : String(options.durationSeconds)
    ], signal);
  }

  async extractFrame(inputPath, outputPath, options, signal) {
    return this.#run(["extract-frame", inputPath, outputPath, String(options.atSeconds ?? 0)], signal);
  }

  #run(argumentsList, signal, onProgress) {
    return new Promise((resolve, reject) => {
      const child = spawn(this.executable, [...this.prefixArguments, ...argumentsList], {
        shell: false,
        windowsHide: true,
        stdio: ["ignore", "pipe", "pipe"],
        signal
      });
      let stdout = "";
      let stderr = "";
      let stderrLineBuffer = "";
      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");
      child.stdout.on("data", chunk => {
        stdout += chunk;
        if (stdout.length > 2_000_000) child.kill();
      });
      child.stderr.on("data", chunk => {
        stderr += chunk;
        if (stderr.length > 2_000_000) stderr = stderr.slice(-1_000_000);
        const lines = (stderrLineBuffer + chunk).split(/\r?\n/);
        stderrLineBuffer = lines.pop() ?? "";
        for (const line of lines) {
          if (!line.trim()) continue;
          try { const event = JSON.parse(line); if (event.type === "progress") onProgress?.(event.progress); } catch { /* native diagnostics are data, never protocol */ }
        }
      });
      child.on("error", reject);
      child.on("close", code => {
        try {
          const envelope = JSON.parse(stdout.trim());
          if (code === 0 && envelope.ok) resolve(envelope.data);
          else reject(new NativeCliError(envelope.error?.code ?? "native_cli_failed", envelope.error?.message ?? `Native CLI exited with ${code}.`, stderr));
        } catch (error) {
          if (error instanceof NativeCliError) reject(error);
          else reject(new NativeCliError("invalid_native_response", "Cineleaf's native automation bridge returned invalid JSON.", stderr));
        }
      });
    });
  }
}

export class NativeCliError extends Error {
  constructor(code, message, diagnostics) { super(message); this.name = "NativeCliError"; this.code = code; this.diagnostics = diagnostics?.slice(-4000); }
}

function locateCli() {
  const configured = process.env.CINELEAF_AUTOMATION_CLI;
  if (configured) return path.resolve(configured);
  if (process.platform === "win32") return path.join(process.env.LOCALAPPDATA ?? "", "Programs", "Cineleaf", "Automation", "Cineleaf.Automation.exe");
  return "/Applications/Cineleaf.app/Contents/MacOS/CineleafCLI";
}
