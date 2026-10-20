/**
 * lib/exec-safe.js — 可移植的超时执行器（Node 侧）
 *
 * 解决问题：
 *   1. macOS 默认没有 GNU `timeout`。Electron 主进程不能再依赖它。
 *   2. 复杂管道 `timeout 15 bash -c "a | b"` 只会杀掉最外层 shell，
 *      真正干活的子进程可能变成孤儿继续跑。
 *
 * 做法：node 自身计时 → 到点对整个进程组发 SIGTERM，宽限期后 SIGKILL。
 * 用 detached:true 让子进程成为新进程组 leader，这样 kill(-pid) 能覆盖
 * 所有后代（包括管道里的每个环节）。
 *
 * 状态语义（与 lib/status.js 完全一致）：
 *   exitCode===0 且未被信号杀死  → 'success'
 *   exitCode!==0                 → 'failed'
 *   由我们主动超时终止            → 'timed_out'（无论退出码是多少）
 *   超时宽限后仍需 SIGKILL         → 'timed_out' + killedHard=true
 */
'use strict';

const { spawn } = require('child_process');

const DEFAULT_TIMEOUT_MS = 30000;
const DEFAULT_GRACE_MS = 2000;

/**
 * @param {string} cmd      可执行文件（不要拼 shell 字符串）
 * @param {string[]} args   参数数组（防止命令注入）
 * @param {Object} [opts]
 * @param {number} [opts.timeoutMs]
 * @param {number} [opts.graceMs]
 * @param {string} [opts.cwd]
 * @param {Object} [opts.env]
 * @param {Function} [opts.onStdout] (chunk: string)
 * @param {Function} [opts.onStderr] (chunk: string)
 * @param {number} [opts.maxOutputBytes=8*1024*1024] 超出后丢弃多余输出并标记 truncated
 * @returns {Promise<{status:string, code:(number|null), signal:(string|null), timedOut:boolean,
 *                    killedHard:boolean, truncated:boolean, durationMs:number,
 *                    stdout:string, stderr:string, spawnError:(string|null)}>}
 */
function runWithTimeout(cmd, args, opts = {}) {
  const timeoutMs = Number.isFinite(opts.timeoutMs) ? opts.timeoutMs : DEFAULT_TIMEOUT_MS;
  const graceMs = Number.isFinite(opts.graceMs) ? opts.graceMs : DEFAULT_GRACE_MS;
  const maxBytes = Number.isFinite(opts.maxOutputBytes) ? opts.maxOutputBytes : 8 * 1024 * 1024;

  return new Promise((resolve) => {
    const startedAt = Date.now();
    let stdout = '';
    let stderr = '';
    let truncated = false;
    let timedOut = false;
    let killedHard = false;
    let settled = false;
    let graceTimer = null;

    let child;
    try {
      child = spawn(cmd, args, {
        cwd: opts.cwd || process.cwd(),
        env: opts.env || process.env,
        stdio: ['ignore', 'pipe', 'pipe'],
        detached: true, // 新进程组，便于整组终止
      });
    } catch (err) {
      resolve({
        status: 'failed', code: null, signal: null, timedOut: false, killedHard: false,
        truncated: false, durationMs: Date.now() - startedAt, stdout: '', stderr: '',
        spawnError: err.message,
      });
      return;
    }

    const killGroup = (sig) => {
      try {
        if (child.pid) process.kill(-child.pid, sig);
      } catch (e) {
        try { child.kill(sig); } catch (e2) { /* 已退出 */ }
      }
    };

    const append = (which, chunk) => {
      const text = chunk.toString('utf8');
      if (which === 'out') {
        if (stdout.length + text.length > maxBytes) { truncated = true; return; }
        stdout += text;
      } else {
        if (stderr.length + text.length > maxBytes) { truncated = true; return; }
        stderr += text;
      }
    };

    child.stdout.on('data', (d) => {
      append('out', d);
      if (opts.onStdout) { try { opts.onStdout(d.toString('utf8')); } catch (e) {} }
    });
    child.stderr.on('data', (d) => {
      append('err', d);
      if (opts.onStderr) { try { opts.onStderr(d.toString('utf8')); } catch (e) {} }
    });

    const timer = setTimeout(() => {
      timedOut = true;
      killGroup('SIGTERM');
      graceTimer = setTimeout(() => {
        killedHard = true;
        killGroup('SIGKILL');
      }, graceMs);
    }, Math.max(1, timeoutMs));

    const finish = (code, signal, spawnError) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (graceTimer) clearTimeout(graceTimer);

      let status;
      if (spawnError) status = 'failed';
      else if (timedOut) status = 'timed_out';
      else if (code === 0) status = 'success';
      else status = 'failed';

      resolve({
        status, code, signal, timedOut, killedHard, truncated,
        durationMs: Date.now() - startedAt, stdout, stderr,
        spawnError: spawnError || null,
      });
    };

    child.on('error', (err) => finish(null, null, err.message));
    child.on('close', (code, signal) => finish(code, signal, null));
  });
}

module.exports = { runWithTimeout, DEFAULT_TIMEOUT_MS, DEFAULT_GRACE_MS };
