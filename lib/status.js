/**
 * lib/status.js — 单一状态定义来源（Shell / Node / 渲染层三方共用）
 *
 * 任何模块采集结果只能是以下枚举之一。UI、manifest.json、summary.json
 * 全部使用同一套字符串，避免「脚本退出码 0 == 采集成功」这种错误假设。
 *
 * 该文件只包含约束与算法，不依赖 electron，可被 Node 直接单元测试。
 */
'use strict';

const STATUS = Object.freeze({
  SUCCESS: 'success',                 // 命令正常执行并产出预期结果
  PARTIAL: 'partial',                 // 部分成功（输出被截断 / 子命令部分失败）
  FAILED: 'failed',                   // 已执行但失败（命令报错 / 非零退出）
  TIMED_OUT: 'timed_out',             // 超时被终止
  PERMISSION_DENIED: 'permission_denied', // 因权限/TCC/管理员授权不足无法采集
  NOT_COLLECTED: 'not_collected',     // 未执行（模块被跳过 / 依赖缺失）
  UNSUPPORTED: 'unsupported',         // 当前系统版本不支持（如系统工具缺失）
});

const STATUS_VALUES = Object.values(STATUS);

// 整体采集状态
const OVERALL = Object.freeze({
  SUCCESS: 'success',
  PARTIAL: 'partial',
  FAILED: 'failed',
  INCOMPLETE: 'incomplete',           // 关键模块缺失 / 大量未采集
});

/**
 * 模块关键性定义。critical=true 的模块失败会导致整体状态不可能是 success。
 * 与 scripts/lib/*.sh 中的 MODULE_CRITICAL_MAP 保持一致。
 */
const MODULE_CRITICAL = Object.freeze({
  // online
  'network-connections': true,
  'network-listeners': true,
  'network-config': false,
  'tunnels': false,
  'online-summary': false,
  // offline
  'system-info': true,
  'processes': true,
  'persistence': true,
  'auth-accounts': false,
  'remote-access': false,
  'logs': false,
  'filesystem': false,
  'security-mechanisms': false,
  'crashes': false,
  'ioc-zeff': true,
  'ioc-scanner': true,
  'execution-history': false,
  'timeline': false,
  'evidence-integrity': true,
  'offline-summary': false,
});

function isCritical(moduleId) {
  return MODULE_CRITICAL[moduleId] === true;
}

/**
 * 计算整体采集状态。
 *
 * @param {Array<{id:string,status:string}>} modules 已注册的模块结果
 * @param {Object} [opts]
 * @param {number} [opts.deferred]  尚未运行的阶段模块数（例如离线阶段尚未执行）
 * @returns {{status:string, reason:string, counts:Object, criticalFailures:string[], notCollected:string[]}}
 */
function computeOverall(modules, opts = {}) {
  const list = Array.isArray(modules) ? modules.filter(Boolean) : [];
  const counts = {};
  for (const s of STATUS_VALUES) counts[s] = 0;

  for (const m of list) {
    const st = STATUS_VALUES.includes(m.status) ? m.status : STATUS.NOT_COLLECTED;
    counts[st] += 1;
  }

  const criticalFailures = list
    .filter((m) => STATUS_VALUES.includes(m.status) && isCritical(m.id) &&
      [STATUS.FAILED, STATUS.TIMED_OUT, STATUS.PERMISSION_DENIED, STATUS.NOT_COLLECTED].includes(m.status))
    .map((m) => m.id);

  const notCollected = list
    .filter((m) => m.status === STATUS.NOT_COLLECTED || m.status === STATUS.PERMISSION_DENIED)
    .map((m) => m.id);

  const total = list.length;
  const ran = total - counts[STATUS.NOT_COLLECTED];

  // 未注册任何模块 = 什么都没采集到，绝不能报成功
  if (total === 0) {
    return { status: OVERALL.FAILED, reason: '没有注册任何采集模块（脚本可能未启动）', counts, criticalFailures, notCollected };
  }
  // 一个模块都没真正执行
  if (ran === 0) {
    return { status: OVERALL.FAILED, reason: '所有模块均未执行', counts, criticalFailures, notCollected };
  }
  // 还有阶段模块尚未运行 → 至少是 incomplete，不允许显示完整成功
  if (opts.deferred && opts.deferred > 0) {
    return {
      status: OVERALL.INCOMPLETE,
      reason: `还有 ${opts.deferred} 个模块尚未执行（例如离线阶段未开始）`,
      counts, criticalFailures, notCollected
    };
  }
  if (criticalFailures.length > 0) {
    const anyTimedOut = list.some((m) => m.status === STATUS.TIMED_OUT && isCritical(m.id));
    return {
      status: anyTimedOut ? OVERALL.INCOMPLETE : OVERALL.FAILED,
      reason: `关键模块未成功: ${criticalFailures.join(', ')}`,
      counts, criticalFailures, notCollected
    };
  }
  const degraded = counts[STATUS.PARTIAL] + counts[STATUS.FAILED] + counts[STATUS.TIMED_OUT] +
    counts[STATUS.PERMISSION_DENIED] + counts[STATUS.NOT_COLLECTED];
  if (degraded > 0) {
    return {
      status: OVERALL.PARTIAL,
      reason: `${degraded} 个模块未完整执行（见模块明细）`,
      counts, criticalFailures, notCollected
    };
  }
  return { status: OVERALL.SUCCESS, reason: '全部模块成功执行', counts, criticalFailures, notCollected };
}

/** 人类可读标签（UI 与 README 一致） */
const STATUS_LABEL_ZH = Object.freeze({
  success: '成功',
  partial: '部分成功',
  failed: '失败',
  timed_out: '超时',
  permission_denied: '权限不足',
  not_collected: '未采集',
  unsupported: '不支持',
  incomplete: '不完整',
});

module.exports = { STATUS, STATUS_VALUES, OVERALL, MODULE_CRITICAL, STATUS_LABEL_ZH, computeOverall, isCritical };
