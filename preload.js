const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
  // 启动扫描（invoke = 双向通信，等待结果）
  startScan: () => ipcRenderer.invoke('start-scan'),

  // 监听实时进度（单向，主进程推送）
  onProgress: (callback) => {
    ipcRenderer.on('scan-progress', (_event, message) => callback(message));
  },

  // 移除进度监听（清理用）
  removeProgressListener: () => {
    ipcRenderer.removeAllListeners('scan-progress');
  },

  // 在 Finder 中显示文件
  showInFinder: (filePath) => ipcRenderer.invoke('show-in-finder', filePath),

  // 复制文件路径到剪贴板
  copyPath: (filePath) => ipcRenderer.invoke('copy-path', filePath)
});
