@echo off
chcp 65001 >nul

set SRC=c:\脚本\TrollAutoTouch\_tmp_extracted\Payload\TrollAutoScript.app\svip\lib
set DST=c:\脚本\TrollAutoTouch\TrollAutoTouch\Resources\lua

md "%DST%\croissant" 2>nul
md "%DST%\lluv" 2>nul
md "%DST%\log" 2>nul
md "%DST%\path" 2>nul
md "%DST%\websocket" 2>nul
md "%DST%\lzmq" 2>nul
md "%DST%\res" 2>nul

xcopy "%SRC%\*.lua" "%DST%\" /Y /I /Q
xcopy "%SRC%\*.tas" "%DST%\" /Y /I /Q
xcopy "%SRC%\*.crt" "%DST%\" /Y /I /Q
xcopy "%SRC%\croissant\*.lua" "%DST%\croissant\" /Y /I /Q
xcopy "%SRC%\lluv\*.lua" "%DST%\lluv\" /Y /I /Q
xcopy "%SRC%\log\*.lua" "%DST%\log\" /Y /I /Q
xcopy "%SRC%\path\*.lua" "%DST%\path\" /Y /I /Q
xcopy "%SRC%\websocket\*.lua" "%DST%\websocket\" /Y /I /Q
xcopy "%SRC%\lzmq\*.lua" "%DST%\lzmq\" /Y /I /Q

set SRCRES=c:\脚本\TrollAutoTouch\_tmp_extracted\Payload\TrollAutoScript.app\svip\res
xcopy "%SRCRES%\*" "%DST%\res\" /Y /I /Q /E

echo Done!
dir /s /b "%DST%\*.lua" 2>nul | find /c /v ""
