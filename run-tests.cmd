@echo off
echo ===================================
echo INICIANDO BATERIA DE TESTS
echo ===================================

echo.
node n8n-validator\test-suite.js

echo.
powershell.exe -ExecutionPolicy Bypass -File test-suite.ps1

echo.
echo ===================================
echo TESTS FINALIZADOS
echo ===================================
