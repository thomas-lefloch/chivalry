
@echo off
if not exist "build" mkdir build
if not exist "build\shaders" mkdir build\shaders

@echo on
call compile_shaders.bat
odin build src -out:build\chivalry.exe