/**
 * lib/privacy.js — 有边界的脱敏规则
 *
 * 原则：
 *   - 宁可少采集，不要无差别输出环境变量。
 *   - 对可识别的 secret 形状做定向替换，避免把普通日志大面积破坏。
 *   - 明确边界：脱敏是 best-effort，不能声称 100% 有效。
 *
 * 所有替换都保留一个可辨识的前缀，方便分析人员知道「这里原本有内容」。
 */
'use strict';

const RULES = [
  // URL 内嵌凭据： scheme://user:pass@host → scheme://[REDACTED:CRED]@host
  {
    name: 'url_credentials',
    re: /\b([a-zA-Z][a-zA-Z0-9+.-]*:\/\/)([^\/\s:@]+):([^\/\s@]+)@/g,
    to: '$1[REDACTED:CRED]@',
  },
  // Bearer / Basic 令牌
  {
    name: 'bearer_token',
    re: /\b(Bearer|Basic)\s+([A-Za-z0-9\-._~+\/]{16,}=*)/gi,
    to: '$1 [REDACTED:TOKEN]',
  },
  // AWS
  { name: 'aws_akid', re: /\b(AKIA|ASIA)[0-9A-Z]{16}\b/g, to: '[REDACTED:AWS_KEY_ID]' },
  { name: 'aws_secret', re: /\baws_secret_access_key\s*[=:]\s*\S+/gi, to: 'aws_secret_access_key=[REDACTED:AWS_SECRET]' },
  // GitHub / GitLab / Slack / Stripe / OpenAI / Anthropic / Google
  { name: 'github_pat', re: /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g, to: '[REDACTED:GITHUB_TOKEN]' },
  { name: 'gitlab_pat', re: /\bglpat-[A-Za-z0-9\-_]{16,}\b/g, to: '[REDACTED:GITLAB_TOKEN]' },
  { name: 'slack_token', re: /\bxox[abposr]-[A-Za-z0-9-]{10,}\b/g, to: '[REDACTED:SLACK_TOKEN]' },
  { name: 'stripe_key', re: /\b(sk|rk)_(live|test)_[A-Za-z0-9]{16,}\b/g, to: '[REDACTED:STRIPE_KEY]' },
  { name: 'openai_key', re: /\bsk-[A-Za-z0-9]{20,}\b/g, to: '[REDACTED:OPENAI_KEY]' },
  { name: 'anthropic_key', re: /\bsk-ant-[A-Za-z0-9\-_]{20,}\b/g, to: '[REDACTED:ANTHROPIC_KEY]' },
  { name: 'google_api_key', re: /\bAIza[0-9A-Za-z\-_]{35}\b/g, to: '[REDACTED:GOOGLE_API_KEY]' },
  { name: 'jwt', re: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g, to: '[REDACTED:JWT]' },
  // PEM 私钥块（多行）
  {
    name: 'pem_private_key',
    re: /-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z ]+ )?PRIVATE KEY-----/g,
    to: '[REDACTED:PRIVATE_KEY_BLOCK]',
  },
  // 通用 key=value 形式的敏感键
  {
    name: 'kv_secret',
    re: /\b([A-Za-z0-9_.-]*(?:password|passwd|secret|token|api[_-]?key|apikey|access[_-]?key|auth[_-]?token|client[_-]?secret|session[_-]?id|cookie)[A-Za-z0-9_.-]*)\s*[=:]\s*("?)([^\s"'`;]{6,})\2/gi,
    to: '$1=[REDACTED]',
  },
  // 明确列出的代理变量（保留变量名与主机，去掉凭据）
  {
    name: 'proxy_env',
    re: /\b((?:https?|all|ftp|socks)_proxy)\s*=\s*(\S+)/gi,
    to: '$1=[REDACTED:PROXY_ENV]',
  },
];

/** 允许环境变量白名单（代理类）——只记录键名 + 结构，不记录完整值 */
const PROXY_ENV_KEYS = [
  'http_proxy', 'https_proxy', 'all_proxy', 'ftp_proxy', 'socks_proxy', 'no_proxy',
  'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'FTP_PROXY', 'SOCKS_PROXY', 'NO_PROXY',
];

/**
 * 对单行/多行文本脱敏。
 * @param {string} text
 * @param {Object} [opts]
 * @param {string[]} [opts.allowRules] 只启用这些规则（测试用）
 * @returns {{text:string, hits:Object<string,number>}}
 */
function redactText(text, opts = {}) {
  if (typeof text !== 'string' || !text) return { text: text || '', hits: {} };
  let out = text;
  const hits = {};
  for (const rule of RULES) {
    if (opts.allowRules && !opts.allowRules.includes(rule.name)) continue;
    let count = 0;
    out = out.replace(rule.re, (...m) => {
      count += 1;
      // 支持 $1 风格替换
      if (rule.to.includes('$')) {
        const groups = m.slice(1, -2);
        return rule.to.replace(/\$(\d)/g, (_, n) => groups[Number(n) - 1] ?? '');
      }
      return rule.to;
    });
    if (count > 0) hits[rule.name] = (hits[rule.name] || 0) + count;
  }
  return { text: out, hits };
}

/**
 * 解析代理 URL 为结构化对象，userinfo 一律丢弃（不落盘）。
 * @returns {{scheme:string|null, host:string|null, port:string|null, hasCredentials:boolean}|null}
 */
function parseProxyUrl(value) {
  if (!value || typeof value !== 'string') return null;
  try {
    const normalized = value.includes('://') ? value : `http://${value}`;
    const u = new URL(normalized);
    return {
      scheme: u.protocol.replace(':', ''),
      host: u.hostname || null,
      port: u.port || null,
      hasCredentials: Boolean(u.username || u.password),
    };
  } catch (e) {
    return { scheme: null, host: null, port: null, hasCredentials: /@/.test(value) };
  }
}

/** 从 env 对象里挑出代理变量并结构化，绝不输出完整值 */
function describeProxyEnv(env) {
  const result = {};
  if (!env) return result;
  for (const key of PROXY_ENV_KEYS) {
    if (env[key] !== undefined) {
      const parsed = parseProxyUrl(env[key]);
      result[key] = parsed
        ? { scheme: parsed.scheme, host: parsed.host, port: parsed.port, hasCredentials: parsed.hasCredentials }
        : { raw: '[REDACTED:PROXY_ENV]' };
    }
  }
  return result;
}

module.exports = { redactText, parseProxyUrl, describeProxyEnv, PROXY_ENV_KEYS, RULES };
