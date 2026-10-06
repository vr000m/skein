# Native Release Launch Contract

Use a verified runtime-native process API for the adapter and every subsequent release command. The API must take an executable path and argv separately, supply an explicit child environment before creation, and avoid a shell. A native Node REPL exposing `node:child_process.spawn` supports this contract; discover and verify the real tool, never invent an API. A shell override, a successful command or an in-shell environment reset does not prove these properties. Missing support stops the release before any application-tool execution.

In a verified native Node REPL, define this transport once. The runtime and installed adapter are trusted bootstrap code. Use only standard library imports; do not import `node:process` or copy ambient environment state.

```javascript
var releaseSpawn = (await import('node:child_process')).spawn;
var releaseRun = ({executable, argv, env, cwd, stdin = ''}) =>
  new Promise((resolve, reject) => {
    if (typeof executable !== 'string' || !executable.startsWith('/') ||
        !Array.isArray(argv) || !argv.every(value => typeof value === 'string') ||
        typeof cwd !== 'string' || !cwd.startsWith('/') ||
        !env || typeof env !== 'object' || Array.isArray(env) ||
        !Object.values(env).every(value => typeof value === 'string')) {
      reject(new Error('Explicit absolute executable/cwd, argv and env required'));
      return;
    }
    var chunks = [], errors = [];
    var child = releaseSpawn(executable, argv, {
      env, cwd, shell: false, stdio: ['pipe', 'pipe', 'pipe']
    });
    child.stdout.on('data', data => chunks.push(data));
    child.stderr.on('data', data => errors.push(data));
    child.stdin.on('error', reject);
    child.on('error', reject);
    child.on('close', code => resolve({code,
      stdout: Buffer.concat(chunks).toString(),
      stderr: Buffer.concat(errors).toString()}));
    child.stdin.end(stdin);
  });
```

Fill requests as structured data, escaping values through JSON serialization rather than interpolating them into code or shell command strings. Always supply `env` and an absolute `cwd`; omitting `env` would inherit ambient state. For the initial macOS metadata-only bootstrap, the request is:

```json
{
  "executable": "/usr/bin/env",
  "argv": ["-i", "/usr/bin/python3", "-I", "-S", "{{ABSOLUTE_SKILL_DIR}}/executable_policy.py", "--candidate", "{{ABSOLUTE_TOOL_CANDIDATE}}"],
  "env": {},
  "cwd": "{{ABSOLUTE_CALLER_CWD}}"
}
```

Add each additional candidate as a separate `--candidate`, absolute-path pair. Save successful adapter stdout as the trusted pin document. Device/inode fields are decimal strings to preserve values above JavaScript's exact integer range; retain the document losslessly anyway. Immediately before each application-tool launch, run the same bootstrap argv with `--verify-stdin` instead of candidate arguments and pass the trusted pin document as `stdin`. Any nonzero exit, launch error or identity drift stops the workflow.

Application-tool requests use only the recorded canonical executable path, explicit argv, the pinned source/transport `cwd`, and the exact-name environment values admitted by SKILL.md. Never merge ambient variables or fall back to `exec_command`. This transport supplies process isolation; it does not replace the source, configuration, helper-graph, credential or immutable-destination checks. Do not print authentication inputs or tool output containing secrets.
