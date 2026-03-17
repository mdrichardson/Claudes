Set WshShell = CreateObject("WScript.Shell")
WshShell.CurrentDirectory = "C:\Users\paul\Git\Claudes"
WshShell.Run "cmd /c npm start", 0, False
