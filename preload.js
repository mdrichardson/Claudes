const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
  openDirectoryDialog: () => ipcRenderer.invoke('dialog:openDirectory'),
  getProjects: () => ipcRenderer.invoke('config:getProjects'),
  saveProjects: (config) => ipcRenderer.invoke('config:saveProjects', config)
});
