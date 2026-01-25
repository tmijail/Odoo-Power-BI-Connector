# CLI Testing Approach with PQTest

## Overview

The Power Query SDK includes **PQTest.exe**, a command-line test harness that can run tests without VS Code. This enables:
- Automated testing in CI/CD pipelines
- Faster development iteration
- Reproducible test runs

## Installation

### Option 1: From NuGet Package (Recommended for CI)
```bash
# Download the SDK tools package
nuget install Microsoft.PowerQuery.SdkTools -OutputDirectory ./tools

# PQTest.exe location:
# ./tools/Microsoft.PowerQuery.SdkTools.X.X.X/tools/PQTest.exe
```

### Option 2: From VS Code Extension
If the Power Query SDK extension is installed, PQTest.exe is at:
```
~/.vscode/extensions/powerquery.vscode-powerquery-sdk-<version>/nuget/Microsoft.PowerQuery.SdkTools.<version>/tools/PQTest.exe
```

## Test Commands

### Build the Connector
```bash
# Using MSBuild (requires .NET SDK)
dotnet build Odoo.proj

# Or use the Power Query SDK build
msbuild Odoo.proj /t:Build
```

Output: `bin/AnyCPU/Debug/Odoo.mez`

### Set Credentials
Before running tests, credentials must be set:

```bash
# Generate a credential template
PQTest.exe credential-template \
  -e bin/AnyCPU/Debug/Odoo.mez \
  -q Odoo.query.pq \
  -ak UsernamePassword \
  -p

# Output:
# {
#   "AuthenticationKind": "UsernamePassword",
#   "AuthenticationProperties": {
#     "Username": "$$USERNAME$$",
#     "Password": "$$PASSWORD$$"
#   },
#   "PrivacySetting": "None",
#   "Permissions": []
# }

# Set credentials (pipe JSON to set-credential)
echo '{"AuthenticationKind":"UsernamePassword","AuthenticationProperties":{"Username":"admin","Password":"admin"},"PrivacySetting":"None","Permissions":[]}' | \
  PQTest.exe set-credential \
    -e bin/AnyCPU/Debug/Odoo.mez \
    -q Odoo.query.pq

# Verify credentials are set
PQTest.exe list-credential
```

### Run Tests

```bash
# Run a single test file
PQTest.exe compare \
  -e bin/AnyCPU/Debug/Odoo.mez \
  -q Odoo.query.pq \
  -p  # pretty print

# Run all tests in a folder
PQTest.exe compare \
  -e bin/AnyCPU/Debug/Odoo.mez \
  -q ./tests/ \
  -p
```

### Using a Settings File

Create `pqtest-settings.json`:
```json
{
  "ExtensionPaths": ["bin/AnyCPU/Debug/Odoo.mez"],
  "QueryFilePath": "Odoo.query.pq",
  "FailOnMissingOutputFile": false
}
```

Run with settings:
```bash
PQTest.exe compare -sf pqtest-settings.json -p
```

## Regression Testing with .pqout Files

PQTest uses `.pqout` files for regression testing:

1. **First run**: Generates `Odoo.query.pqout` with test results
2. **Subsequent runs**: Compares output against `.pqout` file
3. **Fail on mismatch**: Use `-fomof` flag to fail if output differs

```bash
# Fail if output doesn't match expected
PQTest.exe compare \
  -e bin/AnyCPU/Debug/Odoo.mez \
  -q Odoo.query.pq \
  -fomof
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Test Power Query Connector

on: [push, pull_request]

jobs:
  test:
    runs-on: windows-latest

    steps:
      - uses: actions/checkout@v4

      - name: Install Power Query SDK
        run: |
          nuget install Microsoft.PowerQuery.SdkTools -OutputDirectory ./tools
          $pqtest = (Get-ChildItem -Path ./tools -Recurse -Filter PQTest.exe).FullName
          echo "PQTEST=$pqtest" >> $env:GITHUB_ENV

      - name: Build connector
        run: dotnet build Odoo.proj

      - name: Start Odoo test server
        run: docker-compose up -d

      - name: Wait for Odoo
        run: |
          # Wait for Odoo to be ready
          timeout 120 bash -c 'until curl -s http://localhost:8069/web/version; do sleep 2; done'

      - name: Set credentials
        run: |
          echo '{"AuthenticationKind":"UsernamePassword","AuthenticationProperties":{"Username":"admin","Password":"admin"},"PrivacySetting":"None","Permissions":[]}' | `
            & $env:PQTEST set-credential -e bin/AnyCPU/Debug/Odoo.mez -q Odoo.query.pq

      - name: Run tests
        run: |
          & $env:PQTEST compare -e bin/AnyCPU/Debug/Odoo.mez -q Odoo.query.pq -p -fomof
```

### Local Test Script

Create `run-tests.ps1`:
```powershell
#!/usr/bin/env pwsh

$ErrorActionPreference = "Stop"

# Configuration
$ExtensionPath = "bin/AnyCPU/Debug/Odoo.mez"
$QueryFile = "Odoo.query.pq"
$TestServerUrl = "http://localhost:8069"

# Find PQTest
$PQTest = Get-ChildItem -Path "$env:USERPROFILE/.vscode/extensions" -Recurse -Filter "PQTest.exe" -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -match "powerquery" } |
          Select-Object -First 1 -ExpandProperty FullName

if (-not $PQTest) {
    Write-Error "PQTest.exe not found. Install the Power Query SDK VS Code extension."
    exit 1
}

Write-Host "Using PQTest: $PQTest"

# Build
Write-Host "`nBuilding connector..."
dotnet build Odoo.proj
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Check if Odoo is running
Write-Host "`nChecking test server..."
try {
    Invoke-RestMethod -Uri "$TestServerUrl/web/database/list" -Method POST -ContentType "application/json" -Body "{}" | Out-Null
    Write-Host "Test server is running"
} catch {
    Write-Error "Test server not running. Start with: docker-compose up -d"
    exit 1
}

# Set credentials
Write-Host "`nSetting credentials..."
$cred = '{"AuthenticationKind":"UsernamePassword","AuthenticationProperties":{"Username":"admin","Password":"admin"},"PrivacySetting":"None","Permissions":[]}'
$cred | & $PQTest set-credential -e $ExtensionPath -q $QueryFile

# Run tests
Write-Host "`nRunning tests..."
& $PQTest compare -e $ExtensionPath -q $QueryFile -p

exit $LASTEXITCODE
```

Create `run-tests.sh` for Linux/macOS:
```bash
#!/bin/bash
set -e

EXTENSION_PATH="bin/AnyCPU/Debug/Odoo.mez"
QUERY_FILE="Odoo.query.pq"
TEST_SERVER_URL="http://localhost:8069"

# Find PQTest (Linux/macOS path)
PQTEST=$(find ~/.vscode/extensions -name "PQTest.exe" 2>/dev/null | grep powerquery | head -1)

if [ -z "$PQTEST" ]; then
    echo "Error: PQTest.exe not found. Install the Power Query SDK VS Code extension."
    exit 1
fi

echo "Using PQTest: $PQTEST"

# Build
echo -e "\nBuilding connector..."
dotnet build Odoo.proj

# Check if Odoo is running
echo -e "\nChecking test server..."
if ! curl -s "$TEST_SERVER_URL/web/database/list" -X POST -H "Content-Type: application/json" -d "{}" > /dev/null; then
    echo "Error: Test server not running. Start with: docker-compose up -d"
    exit 1
fi
echo "Test server is running"

# Set credentials
echo -e "\nSetting credentials..."
echo '{"AuthenticationKind":"UsernamePassword","AuthenticationProperties":{"Username":"admin","Password":"admin"},"PrivacySetting":"None","Permissions":[]}' | \
    mono "$PQTEST" set-credential -e "$EXTENSION_PATH" -q "$QUERY_FILE"

# Run tests
echo -e "\nRunning tests..."
mono "$PQTEST" compare -e "$EXTENSION_PATH" -q "$QUERY_FILE" -p
```

## Command Reference

| Command | Description |
|---------|-------------|
| `credential-template` | Generate JSON template for credentials |
| `set-credential` | Store credentials for test runs |
| `list-credential` | Show stored credentials |
| `delete-credential` | Remove stored credentials |
| `compare` | Run tests and compare against expected output |
| `run-test` | Run a single test (deprecated, use `compare`) |

### Common Options

| Option | Short | Description |
|--------|-------|-------------|
| `--extension` | `-e` | Path to connector (.mez) file |
| `--queryFile` | `-q` | Path to test query file |
| `--prettyPrint` | `-p` | Format output for readability |
| `--settingsFile` | `-sf` | Path to JSON settings file |
| `--authenticationKind` | `-ak` | Auth type (Anonymous, UsernamePassword, Key, etc.) |
| `--failOnMissingOutputFile` | `-fomof` | Fail if .pqout file doesn't exist |

## Advantages Over VS Code Testing

1. **Automation**: Can run in CI/CD without GUI
2. **Reproducibility**: Same command produces same results
3. **Speed**: No VS Code startup overhead
4. **Scripting**: Easy to integrate with build systems
5. **Regression**: Built-in output comparison with .pqout files
