// ─── DOM 元素 ───
const scanBtn = document.getElementById('scanBtn');
const scanArea = document.getElementById('scanArea');
const shieldIcon = document.getElementById('shieldIcon');
const progressContainer = document.getElementById('progressContainer');
const progressFill = document.getElementById('progressFill');
const progressText = document.getElementById('progressText');
const logContent = document.getElementById('logContent');
const resultPanel = document.getElementById('resultPanel');
const resultFilename = document.getElementById('resultFilename');
const resultSize = document.getElementById('resultSize');
const finderBtn = document.getElementById('finderBtn');
const copyBtn = document.getElementById('copyBtn');

let archivePath = '';
let isScanning = false;

// ─── 进度解析 ───
// 脚本 step() 函数输出: [N/20] 【描述】...
function parseProgress(line) {
  const match = line.match(/\[(\d+)\/(\d+)\]/);
  if (match) {
    const current = parseInt(match[1]);
    const total = parseInt(match[2]);
    return { current, total, percent: Math.round((current / total) * 100) };
  }
  return null;
}

// ─── 添加日志行 ───
function addLogLine(text, type = 'info') {
  const line = document.createElement('span');
  line.className = `log-line ${type}`;
  line.textContent = text;
  logContent.appendChild(line);
  logContent.appendChild(document.createTextNode('\n'));
  logContent.scrollTop = logContent.scrollHeight;
}

// ─── 更新进度条 ───
function updateProgress(current, total) {
  const percent = Math.round((current / total) * 100);
  progressFill.style.width = `${percent}%`;
  progressText.textContent = `${current} / ${total}`;
}

// ─── 显示完成面板 ───
function showResultPanel(path, size) {
  archivePath = path;
  const filename = path.split('/').pop() || path;
  resultFilename.textContent = filename;
  resultSize.textContent = size || '未知大小';

  resultPanel.classList.add('visible');
  progressFill.classList.add('done');
  shieldIcon.classList.remove('scanning');
  shieldIcon.classList.add('done');
}

// ─── 判断日志类型 ───
function classifyLine(text) {
  // ✓ 开头 = success
  if (text.startsWith('✓')) return 'success';
  // ⚠ 开头 = warning/info
  if (text.startsWith('⚠')) return 'info';
  // ✗ 开头 = error
  if (text.startsWith('✗')) return 'error';
  // ✅ 或 完成 = success
  if (text.includes('✅') || text.includes('采集完成')) return 'success';
  // [STEP/TOTAL] = pending (正在采集)
  if (/\[\d+\/\d+\]/.test(text)) return 'pending';
  // ╔ ║ ╚ 装饰线 = info
  if (/^[╔║╚═╗╝]/.test(text)) return 'info';
  // 提示/注意 = info
  if (text.startsWith('注意') || text.startsWith('提示') || text.startsWith('下一步')) return 'info';
  // 错误/失败 = error
  if (text.includes('失败') || text.includes('错误') || text.includes('中断')) return 'error';
  // 权限相关 = info
  if (text.includes('权限') || text.includes('sudo') || text.includes('🔑')) return 'info';
  // 其他
  return 'info';
}

// ─── 主进程推送的进度消息 ───
window.electronAPI.onProgress((message) => {
  const progress = parseProgress(message);

  if (progress) {
    updateProgress(progress.current, progress.total);
    addLogLine(message, 'pending');
  } else {
    const type = classifyLine(message);
    addLogLine(message, type);
  }
});

// ─── 开始扫描 ───
scanBtn.addEventListener('click', async () => {
  if (isScanning) return;
  isScanning = true;

  scanBtn.disabled = true;
  scanBtn.querySelector('.btn-text').textContent = '扫描中...';
  shieldIcon.classList.add('scanning');
  progressContainer.classList.add('visible');
  resultPanel.classList.remove('visible');
  logContent.innerHTML = '';

  try {
    const result = await window.electronAPI.startScan();

    if (result.success) {
      addLogLine('✅ 采集完成！', 'success');

      if (result.archivePath) {
        showResultPanel(result.archivePath, result.fileSize);
      } else {
        addLogLine('⚠️ 未能自动检测输出文件，请检查桌面 MacSecCollect_*.zip', 'info');
        scanBtn.disabled = false;
        scanBtn.querySelector('.btn-text').textContent = '重新扫描';
        shieldIcon.classList.remove('scanning');
        shieldIcon.classList.add('done');
      }
    } else {
      addLogLine(`❌ 扫描失败: ${result.error}`, 'error');
      scanBtn.disabled = false;
      scanBtn.querySelector('.btn-text').textContent = '重新扫描';
      shieldIcon.classList.remove('scanning');
    }
  } catch (err) {
    addLogLine(`❌ 异常: ${err.message}`, 'error');
    scanBtn.disabled = false;
    scanBtn.querySelector('.btn-text').textContent = '重新扫描';
    shieldIcon.classList.remove('scanning');
  }

  isScanning = false;
});

// ─── Finder 按钮 ───
finderBtn.addEventListener('click', async () => {
  if (archivePath) {
    await window.electronAPI.showInFinder(archivePath);
  }
});

// ─── 复制路径按钮 ───
copyBtn.addEventListener('click', async () => {
  if (archivePath) {
    await window.electronAPI.copyPath(archivePath);
    const originalText = copyBtn.innerHTML;
    copyBtn.innerHTML = '<span>✅</span> 已复制！';
    setTimeout(() => {
      copyBtn.innerHTML = originalText;
    }, 2000);
  }
});
