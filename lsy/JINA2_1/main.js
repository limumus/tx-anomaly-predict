import { app, BrowserWindow, ipcMain } from 'electron';
import path from 'path';
import { fileURLToPath } from 'url';
import axios from 'axios';
import fs from 'fs';
import os from 'os';

// 获取当前文件路径和目录
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

let mainWindow;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1706,
    height: 981,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      enableRemoteModule: false,
      sandbox: true,
    },
  });

  mainWindow.loadURL('http://localhost:3000');
}

// 读取历史记录
const getHistory = () => {
  const historyPath = path.join(__dirname, 'history.txt');
  if (fs.existsSync(historyPath)) {
    const history = fs.readFileSync(historyPath, 'utf-8').split('\n');
    return history.filter(Boolean);  // 过滤空白行
  }
  return [];
};

// 保存历史记录
const saveToHistory = (query) => {
  const historyPath = path.join(__dirname, 'history.txt');
  fs.appendFileSync(historyPath, query + os.EOL);
};

app.whenReady().then(() => {
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

// IPC 事件处理：调用后端的 Python 服务
ipcMain.handle('process-file', async (event, { query, filePath }) => {
  try {
    const outputPath = path.join(filePath, query, 'character.json');
    if (fs.existsSync(outputPath)) {
      return { status: 'success', data: outputPath };
    } else {
      return { status: 'error', message: 'File not found' };
    }
  } catch (error) {
    console.error('Error:', error);
    return { status: 'error', message: error.message || 'Unknown error' };
  }
});

// IPC 事件：保存历史记录
ipcMain.handle('save-to-history', async (event, query) => {
  saveToHistory(query);
  return true;
});

// IPC 事件：获取历史记录
ipcMain.handle('get-history', async () => {
  return getHistory();
});
