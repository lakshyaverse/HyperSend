@echo off
rem HyperSend CLI, Windows: runs the Node engine from a git clone.
rem Build once first: npm install ^&^& npm run build
setlocal
if not exist "%~dp0..\dist\cli.js" (
  echo hypersend: engine not built yet ^(dist\cli.js^) 1>&2
  echo build it:  npm install ^&^& npm run build 1>&2
  exit /b 1
)
node "%~dp0..\dist\cli.js" %*
endlocal
