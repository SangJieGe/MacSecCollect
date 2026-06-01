// ─── DOM 元素 ───
const onlineBtn = document.getElementById('onlineBtn');
const offlineBtn = document.getElementById('offlineBtn');
const scanArea = document.getElementById('scanArea');
const shieldIcon = document.getElementById('shieldIcon');
const stepHint = document.getElementById('stepHint');
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
let onlineDone = false;

// ─── 进度解析 ───
// 脚本 step() 输出: [N/15] 【描述】...
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
  if (text.startsWith('✓')) return 'success';
  if (text.startsWith('⚠')) return 'info';
  if (text.startsWith('✗')) return 'error';
  if (text.includes('✅') || text.includes('完成')) return 'success';
  if (/\[\d+\/\d+\]/.test(text)) return 'pending';
  if (/^[╔║╚═╗╝]/.test(text)) return 'info';
  if (text.startsWith('注意') || text.startsWith('提示') || text.startsWith('下一步')) return 'info';
  if (text.includes('失败') || text.includes('错误') || text.includes('中断')) return 'error';
  if (text.includes('权限') || text.includes('sudo')) return 'info';
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

// ─── 联网采集 ───
onlineBtn.addEventListener('click', async () => {
  if (isScanning) return;
  isScanning = true;

  onlineBtn.disabled = true;
  onlineBtn.querySelector('.btn-text').textContent = '采集中...';
  shieldIcon.classList.add('scanning');
  progressContainer.classList.add('visible');
  resultPanel.classList.remove('visible');
  logContent.innerHTML = '';

  addLogLine('📡 开始联网采集...', 'pending');

  try {
    const result = await window.electronAPI.startOnlineScan();

    if (result.success) {
      addLogLine('✅ 联网采集完成！', 'success');
      onlineDone = true;

      // 更新按钮和提示
      onlineBtn.querySelector('.btn-text').textContent = '已完成 ✓';
      offlineBtn.disabled = false;
      stepHint.className = 'step-hint step-hint-done';
      stepHint.textContent = '✅ 第二步：请断开网络，然后点击「断网采集」按钮';

      // 弹出断网提示
      await window.electronAPI.showDisconnectAlert();
    } else {
      addLogLine(`❌ 联网采集失败: ${result.error}`, 'error');
      onlineBtn.disabled = false;
      onlineBtn.querySelector('.btn-text').textContent = '联网采集';
      shieldIcon.classList.remove('scanning');
    }
  } catch (err) {
    addLogLine(`❌ 异常: ${err.message}`, 'error');
    onlineBtn.disabled = false;
    onlineBtn.querySelector('.btn-text').textContent = '联网采集';
    shieldIcon.classList.remove('scanning');
  }

  isScanning = false;
});

// ─── 断网采集 ───
offlineBtn.addEventListener('click', async () => {
  if (isScanning || !onlineDone) return;
  isScanning = true;

  offlineBtn.disabled = true;
  offlineBtn.querySelector('.btn-text').textContent = '采集中...';
  addLogLine('🔒 开始断网采集...', 'pending');

  try {
    const result = await window.electronAPI.startOfflineScan();

    if (result.success) {
      addLogLine('✅ 断网采集完成！正在打包...', 'success');

      // 打包
      const archiveResult = await window.electronAPI.createArchive();

      if (archiveResult.success) {
        addLogLine('✅ 打包完成！', 'success');
        offlineBtn.querySelector('.btn-text').textContent = '✅ 已完成';
        offlineBtn.classList.add('done');
        showResultPanel(archiveResult.archivePath, archiveResult.fileSize);
      } else {
        addLogLine(`⚠️ 打包失败: ${archiveResult.error}，数据已保存在临时目录`, 'info');
        offlineBtn.querySelector('.btn-text').textContent = '✅ 已完成';
        offlineBtn.classList.add('done');
        shieldIcon.classList.remove('scanning');
        shieldIcon.classList.add('done');
      }
    } else {
      addLogLine(`❌ 断网采集失败: ${result.error}`, 'error');
      offlineBtn.disabled = false;
      offlineBtn.querySelector('.btn-text').textContent = '断网采集';
    }
  } catch (err) {
    addLogLine(`❌ 异常: ${err.message}`, 'error');
    offlineBtn.disabled = false;
    offlineBtn.querySelector('.btn-text').textContent = '断网采集';
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
