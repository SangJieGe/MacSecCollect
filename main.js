const { app, BrowserWindow, ipcMain, shell, dialog, Notification } = require('electron');
const path = require('path');
const { spawn } = require('child_process');
const fs = require('fs');

let mainWindow;
let sharedOutputDir = ''; // 联网/断网阶段共享的输出目录

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 720,
    height: 560,
    resizable: false,
    title: 'MacSecCollect',
    titleBarStyle: 'hiddenInset',
    backgroundColor: '#0a0e17',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}

app.whenReady().then(createWindow);

app.on('window-all-closed', () => {
  app.quit();
});

// ─── 去除 ANSI 颜色转义码 ───
function stripAnsi(str) {
  return str.replace(/\x1b\[[0-9;]*m/g, '');
}

// ─── 格式化文件大小 ───
function formatBytes(bytes) {
  if (bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}

// ─── 通用脚本执行器 ───
function runScript(scriptName, extraArgs = []) {
  const scriptPath = path.join(__dirname, 'scripts', scriptName);

  if (!fs.existsSync(scriptPath)) {
    return Promise.resolve({ success: false, error: '脚本文件不存在: ' + scriptPath });
  }

  return new Promise((resolve) => {
    const args = [scriptPath, ...extraArgs];
    const child = spawn('bash', args, {
      cwd: path.join(__dirname, 'scripts'),
      env: { ...process.env, FORCE_COLOR: '0', TERM: 'dumb' }
    });

    let stdoutBuffer = '';
    let allOutput = '';

    child.stdout.on('data', (data) => {
      const raw = data.toString();
      const clean = stripAnsi(raw);
      allOutput += clean;
      stdoutBuffer += clean;

      const lines = stdoutBuffer.split('\n');
      stdoutBuffer = lines.pop();

      for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed) {
          // 检查是否包含 OUTPUT_DIR 标记
          if (trimmed.startsWith('OUTPUT_DIR:')) {
            sharedOutputDir = trimmed.replace('OUTPUT_DIR:', '');
          }
          mainWindow.webContents.send('scan-progress', trimmed);
        }
      }
    });

    child.stderr.on('data', (data) => {
      const clean = stripAnsi(data.toString());
      const lines = clean.split('\n');
      for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed) {
          mainWindow.webContents.send('scan-progress', trimmed);
        }
      }
    });

    child.on('close', (code) => {
      if (stdoutBuffer.trim()) {
        mainWindow.webContents.send('scan-progress', stdoutBuffer.trim());
      }

      if (code === 0) {
        resolve({ success: true, outputDir: sharedOutputDir, allOutput });
      } else {
        resolve({ success: false, error: `脚本退出码: ${code}` });
      }
    });

    child.on('error', (err) => {
      resolve({ success: false, error: err.message });
    });
  });
}

// ─── 打包压缩 ───
function createArchive(outputDir) {
  return new Promise((resolve) => {
    if (!outputDir || !fs.existsSync(outputDir)) {
      resolve({ success: false, error: '输出目录不存在' });
      return;
    }

    const archiveName = path.basename(outputDir) + '.zip';
    const desktopPath = path.join(process.env.HOME || '/root', 'Desktop');
    const archivePath = path.join(desktopPath, archiveName);

    const child = spawn('zip', ['-r', archivePath, path.basename(outputDir)], {
      cwd: desktopPath,
      env: { ...process.env }
    });

    let stderr = '';
    child.stderr.on('data', (d) => { stderr += d.toString(); });

    child.on('close', (code) => {
      if (code === 0) {
        // 删除临时目录
        try { fs.rmSync(outputDir, { recursive: true }); } catch (e) {}

        let fileSize = '';
        if (fs.existsSync(archivePath)) {
          fileSize = formatBytes(fs.statSync(archivePath).size);
        }
        resolve({ success: true, archivePath, fileSize });
      } else {
        resolve({ success: false, error: stderr || '压缩失败' });
      }
    });

    child.on('error', (err) => {
      resolve({ success: false, error: err.message });
    });
  });
}

// ─── IPC: 联网采集 ───
ipcMain.handle('start-online-scan', async (event) => {
  // 生成共享输出目录
  const timestamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 15);
  const hostname = require('os').hostname().split('.')[0] || 'mac';
  sharedOutputDir = path.join(
    process.env.HOME || '/root',
    'Desktop',
    `MacSecCollect_${hostname}_${timestamp}`
  );

  const result = await runScript('mac_collect_online.sh', [sharedOutputDir]);
  return { ...result, outputDir: sharedOutputDir };
});

// ─── IPC: 断网采集 ───
ipcMain.handle('start-offline-scan', async (event) => {
  if (!sharedOutputDir) {
    return { success: false, error: '请先完成联网采集' };
  }
  const result = await runScript('mac_collect_offline.sh', [sharedOutputDir]);
  return result;
});

// ─── IPC: 打包 ───
ipcMain.handle('create-archive', async (event) => {
  if (!sharedOutputDir) {
    return { success: false, error: '没有可打包的数据' };
  }
  // 通知渲染进程：开始打包
  mainWindow.webContents.send('scan-progress', '📦 正在打包压缩，请稍候...');
  const result = await createArchive(sharedOutputDir);
  if (result.success) {
    sharedOutputDir = ''; // 清理
  }
  return result;
});

// ─── IPC: 显示断网提示 ───
ipcMain.handle('show-disconnect-alert', async (event) => {
  // 用 osascript 弹系统通知
  const { execSync } = require('child_process');
  try {
    execSync(`osascript -e 'display notification "请立即断开网络连接，然后点击「断网采集」按钮" with title "MacSecCollect" sound name "Submarine"'`, { timeout: 5000 });
  } catch (e) {}

  // 同时弹对话框
  try {
    const result = dialog.showMessageBoxSync(mainWindow, {
      type: 'warning',
      title: 'MacSecCollect',
      message: '联网采集完成！',
      detail: '请立即断开网络连接（WiFi/有线），然后点击「断网采集」按钮继续。',
      buttons: ['已断网，继续', '取消'],
      defaultId: 0
    });
    return result === 0;
  } catch (e) {
    return true;
  }
});

// ─── IPC: 在 Finder 中显示 ───
ipcMain.handle('show-in-finder', async (event, filePath) => {
  if (filePath && fs.existsSync(filePath)) {
    shell.showItemInFolder(filePath);
    return true;
  }
  return false;
});

// ─── IPC: 复制文件路径 ───
ipcMain.handle('copy-path', async (event, filePath) => {
  const { clipboard } = require('electron');
  clipboard.writeText(filePath);
  return true;
});
