const { app, BrowserWindow, ipcMain, shell } = require('electron');
const path = require('path');
const { spawn } = require('child_process');
const fs = require('fs');

let mainWindow;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 680,
    height: 480,
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

// ─── IPC: 开始扫描 ───
ipcMain.handle('start-scan', async (event) => {
  const scriptPath = path.join(__dirname, 'scripts', 'mac_security_collector.sh');

  if (!fs.existsSync(scriptPath)) {
    return { success: false, error: '脚本文件不存在: ' + scriptPath };
  }

  // 先用 AppleScript 弹出管理员密码框，让 sudo 凭据缓存
  // 这样脚本内部的 sudo -v 就不会再次弹窗
  try {
    const osascript = spawn('osascript', [
      '-e',
      'do shell script "sudo -v" with administrator privileges'
    ]);

    await new Promise((resolve, reject) => {
      osascript.on('close', (code) => {
        if (code === 0) resolve();
        else reject(new Error('sudo 授权失败'));
      });
      osascript.on('error', reject);
    });
    mainWindow.webContents.send('scan-progress', '🔑 管理员权限已获取');
  } catch (err) {
    mainWindow.webContents.send('scan-progress', '⚠️ sudo 授权被取消，部分系统级数据将跳过');
  }

  return new Promise((resolve, reject) => {
    // 用 login shell 运行，确保 PATH 完整
    const child = spawn('bash', [scriptPath], {
      cwd: path.join(__dirname, 'scripts'),
      env: { ...process.env, FORCE_COLOR: '0', TERM: 'dumb' }
    });

    let stdoutBuffer = '';
    let allOutput = ''; // 累积所有输出，用于最后提取路径

    child.stdout.on('data', (data) => {
      const raw = data.toString();
      const clean = stripAnsi(raw);
      allOutput += clean;
      stdoutBuffer += clean;

      // 按行分割，保留最后一个不完整的行
      const lines = stdoutBuffer.split('\n');
      stdoutBuffer = lines.pop(); // 保留未完成的行

      for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed) {
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
          // 脚本的 ok/warn/err 输出到 stderr（通过 echo -e）
          // 但也有些真正的错误，都传给前端
          mainWindow.webContents.send('scan-progress', trimmed);
        }
      }
    });

    child.on('close', (code) => {
      // 处理缓冲区中剩余内容
      if (stdoutBuffer.trim()) {
        mainWindow.webContents.send('scan-progress', stdoutBuffer.trim());
      }

      if (code === 0) {
        // 从全部输出中提取压缩包路径
        // 脚本最后输出: 压缩包位置: ~/Desktop/xxx.zip
        // 也可能直接输出路径行
        let archivePath = '';

        // 方式1: 匹配 "压缩包位置:" 后的路径
        const posMatch = allOutput.match(/压缩包位置:\s*(\S+\.zip)/);
        if (posMatch) {
          archivePath = posMatch[1].replace('~', process.env.HOME || '/root');
        }

        // 方式2: 匹配任意 .zip 路径
        if (!archivePath) {
          const zipMatch = allOutput.match(/(\/[^\s]+\.zip)/);
          if (zipMatch) archivePath = zipMatch[1];
        }

        // 方式3: 默认路径 ~/Desktop/
        if (!archivePath) {
          // 脚本格式: MacSecCollect_HOSTNAME_TIMESTAMP.zip
          const desktopPath = path.join(
            process.env.HOME || '/root',
            'Desktop'
          );
          // 找最新的 zip 文件
          try {
            const files = fs.readdirSync(desktopPath)
              .filter(f => f.startsWith('MacSecCollect_') && f.endsWith('.zip'))
              .map(f => ({
                name: f,
                time: fs.statSync(path.join(desktopPath, f)).mtimeMs
              }))
              .sort((a, b) => b.time - a.time);
            if (files.length > 0) {
              archivePath = path.join(desktopPath, files[0].name);
            }
          } catch (e) {
            // Desktop 目录可能不存在（非 macOS 环境）
          }
        }

        let fileSize = '';
        if (archivePath && fs.existsSync(archivePath)) {
          fileSize = formatBytes(fs.statSync(archivePath).size);
        }

        resolve({
          success: true,
          archivePath: archivePath,
          fileSize: fileSize
        });
      } else {
        resolve({
          success: false,
          error: `脚本退出码: ${code}`
        });
      }
    });

    child.on('error', (err) => {
      resolve({ success: false, error: err.message });
    });
  });
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
