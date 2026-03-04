# GitLab CI/CD Pipeline — .NET Framework 4.8 → Artifactory → IIS
## Complete Setup & Configuration Guide

---

## Architecture Overview

```
Developer Push
     │
     ▼
┌─────────────────────────────────────────────────────┐
│                  GitLab CI Pipeline                  │
│                                                      │
│  ┌──────────┐  ┌───────┐  ┌──────┐  ┌───────────┐  │
│  │ Validate │→ │ Build │→ │ Test │→ │ Artifactory│  │
│  └──────────┘  └───────┘  └──────┘  └─────┬─────┘  │
│                                            │         │
│                               ┌────────────▼──────┐  │
│                               │  Deploy Staging   │  │
│                               └────────────┬──────┘  │
│                                            │         │
│                               ┌────────────▼──────┐  │
│                               │ Deploy Production │  │
│                               │  (Manual Gate ✋) │  │
│                               └───────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**Key design decisions:**
- Source code is **never modified** — web.config is replaced at deploy time only
- The web.config is stored as a **GitLab File-type CI variable** per environment
- Production deploy requires **manual approval** in GitLab UI
- Every deploy creates a **timestamped backup** with automatic rollback on failure

---

## Step 1 — GitLab Runner Setup

Your runner must be a **Windows machine** with the following installed.

### 1.1 Install GitLab Runner

```powershell
# Download GitLab Runner
Invoke-WebRequest -Uri "https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-windows-amd64.exe" `
  -OutFile "C:\GitLab-Runner\gitlab-runner.exe"

# Register the runner
C:\GitLab-Runner\gitlab-runner.exe register `
  --url "https://your-gitlab.example.com" `
  --registration-token "YOUR_REGISTRATION_TOKEN" `
  --executor "shell" `
  --shell "powershell" `
  --tag-list "windows,dotnet-framework" `
  --description "Windows .NET Framework Runner"

# Install as Windows Service
C:\GitLab-Runner\gitlab-runner.exe install
C:\GitLab-Runner\gitlab-runner.exe start
```

### 1.2 Required Software on Runner

| Software | Purpose | Download |
|---|---|---|
| Visual Studio Build Tools 2022 | MSBuild for .NET 4.8 | https://visualstudio.microsoft.com/downloads/ |
| .NET Framework 4.8 Targeting Pack | Build target | Windows Update / VS Installer |
| NuGet CLI | Package restore | https://dist.nuget.org/win-x86-commandline/latest/nuget.exe |
| PowerShell 5.1+ | Scripts | Pre-installed on Windows Server 2019+ |

**Visual Studio Build Tools workloads to select:**
- ✅ .NET desktop build tools
- ✅ Web development build tools
- ✅ NuGet targets and build tasks

```powershell
# Quick check — verify MSBuild is available
& "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe" --version
```

### 1.3 Enable WinRM on IIS Servers (for PS Remoting)

Run on **each IIS server** (staging and production):

```powershell
# Enable PowerShell Remoting
Enable-PSRemoting -Force

# Allow remote connections (if firewall is enabled)
Enable-NetFirewallRule -Name "WINRM-HTTP-In-TCP"

# For domain environments — Negotiate auth is default
# For workgroup environments — add to TrustedHosts on runner:
# Set-Item WSMan:\localhost\Client\TrustedHosts -Value "server-hostname-or-ip"

# Verify
Test-WSMan -ComputerName your-iis-server
```

---

## Step 2 — GitLab CI/CD Variables

Go to **GitLab project → Settings → CI/CD → Variables** and add the following.

### 2.1 Required Variables

| Variable | Type | Protected | Masked | Example Value |
|---|---|---|---|---|
| `ARTIFACTORY_URL` | Variable | ✅ | ❌ | `https://artifactory.example.com/artifactory` |
| `ARTIFACTORY_REPO` | Variable | ✅ | ❌ | `dotnet-releases` |
| `ARTIFACTORY_USER` | Variable | ✅ | ❌ | `svc-gitlab-deploy` |
| `ARTIFACTORY_API_KEY` | Variable | ✅ | ✅ | `AKCp5...` |
| `IIS_DEPLOY_HOST_PROD` | Variable | ✅ | ❌ | `prod-web-01.example.com` |
| `IIS_DEPLOY_HOST_STAGING` | Variable | ✅ | ❌ | `staging-web-01.example.com` |
| `IIS_DEPLOY_USER` | Variable | ✅ | ❌ | `DOMAIN\svc-iis-deploy` |
| `IIS_DEPLOY_PASSWORD` | Variable | ✅ | ✅ | `SecureP@ssw0rd` |
| `IIS_SITE_NAME` | Variable | ✅ | ❌ | `MyWebApp` |
| `IIS_APP_POOL_NAME` | Variable | ✅ | ❌ | `MyWebApp_Pool` |
| `IIS_DEPLOY_PATH` | Variable | ✅ | ❌ | `C:\inetpub\wwwroot\MyApp` |
| `WEB_CONFIG_FILE` | **File** | ✅ | ❌ | *(paste web.config content — see below)* |

### 2.2 Setting Up the web.config File Variable

This is the **most important part** — your web.config with environment-specific values is stored entirely inside GitLab, not in source code.

1. Go to **Settings → CI/CD → Variables → Add variable**
2. Set **Key** = `WEB_CONFIG_FILE`
3. Set **Type** = **File** ← critical
4. Paste your full `web.config` content into the **Value** field:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <appSettings>
    <add key="Environment" value="Production" />
    <add key="ApiBaseUrl" value="https://api.prod.example.com" />
    <add key="DatabaseConnectionString" value="Server=prod-db;Database=MyApp;..." />
    <add key="Redis:ConnectionString" value="prod-redis.example.com:6380" />
    <add key="LogLevel" value="Warning" />
    <!-- All your env-specific keys go here -->
  </appSettings>
  <connectionStrings>
    <add name="DefaultConnection"
         connectionString="Data Source=prod-sql;Initial Catalog=MyApp;..."
         providerName="System.Data.SqlClient" />
  </connectionStrings>
  <system.web>
    <compilation debug="false" targetFramework="4.8" />
    <httpRuntime targetFramework="4.8" />
  </system.web>
</configuration>
```

> **How it works:** GitLab writes the file variable content to a temporary file on the runner. The pipeline reads that file path from `$WEB_CONFIG_FILE` and injects it into the deployment package — **replacing** the web.config in your source code without ever modifying the repository.

### 2.3 Per-Environment web.config (Optional — Recommended)

For different configs per environment, create scoped variables:

| Variable | Environment Scope | Value |
|---|---|---|
| `WEB_CONFIG_FILE` | `staging` | *(staging web.config content)* |
| `WEB_CONFIG_FILE` | `production` | *(production web.config content)* |

GitLab will automatically use the correct scoped variable for each deployment job.

---

## Step 3 — .gitlab-ci.yml Configuration

### 3.1 Required Changes in .gitlab-ci.yml

Open the `.gitlab-ci.yml` file and update these values:

```yaml
variables:
  SOLUTION_FILE: "YourSolution.sln"              # ← Your .sln file name
  PROJECT_FILE: "src/YourProject/YourProject.csproj"  # ← Your web project .csproj
  ARTIFACT_NAME: "webapp"                         # ← Your app name (no spaces)
  
  MSBUILD_PATH: "C:\\Program Files\\..."          # ← Adjust to your VS installation
  NUGET_PATH: "C:\\ProgramData\\..."              # ← Path to nuget.exe on runner
```

### 3.2 Branch Strategy

The pipeline runs on:

| Branch/Tag | Stages Run |
|---|---|
| `merge_requests` | validate, build, test |
| `main` | all stages (staging auto, prod manual) |
| `release/*` | all stages (staging auto, prod manual) |

---

## Step 4 — Artifactory Configuration

### 4.1 Create a Local Repository

In Artifactory:
1. **Admin → Repositories → Local → New Local Repository**
2. Package Type: **Generic** (or ZIP)
3. Repository Key: `dotnet-releases` (match `ARTIFACTORY_REPO`)
4. Layout: Match default

### 4.2 Create a Service Account

1. **Admin → Security → Users → New User**
2. Username: `svc-gitlab-deploy`
3. Assign to group with **Deploy/Cache** permission on `dotnet-releases`

### 4.3 Artifact Structure in Artifactory

```
dotnet-releases/
└── webapp/
    ├── latest/
    │   └── webapp-latest.zip          ← Always the most recent build
    ├── 1.0.42/
    │   └── webapp-1.0.42-abc1234.zip
    └── 1.0.43/
        └── webapp-1.0.43-def5678.zip
```

---

## Step 5 — IIS Server Preparation

Run on **each IIS server** before first deployment:

```powershell
# 1. Create deployment directories
New-Item -ItemType Directory -Path "C:\Deployments\Backups" -Force
New-Item -ItemType Directory -Path "C:\Deployments\Staging" -Force
New-Item -ItemType Directory -Path "C:\Deployments\Downloads" -Force

# 2. Create IIS Site (if not already exists)
Import-Module WebAdministration

New-WebAppPool -Name "MyWebApp_Pool"
Set-ItemProperty "IIS:\AppPools\MyWebApp_Pool" managedRuntimeVersion "v4.0"
Set-ItemProperty "IIS:\AppPools\MyWebApp_Pool" startMode "AlwaysRunning"

New-Website -Name "MyWebApp" `
  -PhysicalPath "C:\inetpub\wwwroot\MyApp" `
  -ApplicationPool "MyWebApp_Pool" `
  -Port 80

# 3. Grant deploy user permissions
$acl = Get-Acl "C:\inetpub\wwwroot\MyApp"
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
  "DOMAIN\svc-iis-deploy", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.SetAccessRule($rule)
Set-Acl "C:\inetpub\wwwroot\MyApp" $acl

# Also grant to Backups/Staging/Downloads
@("C:\Deployments\Backups","C:\Deployments\Staging","C:\Deployments\Downloads") | ForEach-Object {
  $acl = Get-Acl $_
  $acl.SetAccessRule($rule)
  Set-Acl $_ $acl
}

# 4. Grant deploy user WinRM permissions
# Add to Remote Management Users group
Add-LocalGroupMember -Group "Remote Management Users" -Member "DOMAIN\svc-iis-deploy"
```

---

## Step 6 — Pipeline Flow Walkthrough

```
Push to main branch
        │
        ▼
┌───────────────────────┐
│ 1. validate           │  NuGet restore, solution check
│    (~1 min)           │
└───────────┬───────────┘
            │
            ▼
┌───────────────────────┐
│ 2. build              │  MSBuild + WebPublish to publish_output/
│    (~3-5 min)         │  Artifacts stored in GitLab
└───────────┬───────────┘
            │
            ▼
┌───────────────────────┐
│ 3. test               │  VSTest runs all *Tests.dll assemblies
│    (~2-5 min)         │  TRX results uploaded to GitLab
└───────────┬───────────┘
            │
            ▼
┌───────────────────────┐
│ 4. publish-artifact   │  ZIP published output
│    (~2 min)           │  Upload versioned ZIP to Artifactory
│                       │  Upload "latest" copy too
│                       │  Save artifact_metadata.json
└───────────┬───────────┘
            │
            ▼
┌───────────────────────┐
│ 5. deploy-staging     │  Download from Artifactory → staging server
│    (~3 min)           │  Inject web.config from GitLab variable
│                       │  Stop pool → backup → deploy → start pool
└───────────┬───────────┘
            │
            ▼  (Manual click required in GitLab UI)
┌───────────────────────┐
│ 6. deploy-production  │  Same as staging but with smoke test
│    (~5 min)           │  Auto-rollback if app pool fails to start
└───────────────────────┘
```

---

## Step 7 — web.config Handling (No Source Code Changes)

Here's exactly what happens at deploy time:

```
GitLab Variable (File type)
  WEB_CONFIG_FILE = /tmp/gitlab-var-abc123   ← temp file on runner
         │
         │  Get-Content -Path $env:WEB_CONFIG_FILE -Raw
         │
         ▼
  $webConfigContent = full XML string
         │
         │  Sent to IIS server via Invoke-Command -ArgumentList
         │
         ▼
  [System.IO.File]::WriteAllText(
    "$stagingPath\web.config",   ← destination in deploy package
    $webConfigContent,
    [UTF8]
  )
         │
         ▼
  robocopy staging → IIS deploy path
  (web.config from GitLab variable is now live on IIS)
```

**Your source code web.config is untouched.** The developer web.config (with local dev settings) stays in the repository. The pipeline web.config (with production secrets) only exists in GitLab CI/CD variables.

---

## Step 8 — Rollback Procedure

### Automatic Rollback
The pipeline automatically rolls back if:
- Robocopy fails during file copy
- App Pool fails to start after deployment

### Manual Rollback

```powershell
# On the IIS server — list available backups
Get-ChildItem "C:\Deployments\Backups" | Sort-Object LastWriteTime -Descending

# Rollback to specific backup
$backupToRestore = "C:\Deployments\Backups\20240315_143022"

Stop-WebAppPool -Name "MyWebApp_Pool"
Start-Sleep -Seconds 5

robocopy $backupToRestore "C:\inetpub\wwwroot\MyApp" /MIR

Start-WebAppPool -Name "MyWebApp_Pool"
Start-Website -Name "MyWebApp"

Write-Host "Rollback complete from: $backupToRestore"
```

### Redeploy Previous Version via GitLab

1. Go to **GitLab → CI/CD → Pipelines**
2. Find the previous successful pipeline
3. Click the **deploy:production** job
4. Click **Run again** (this re-downloads that pipeline's artifact from Artifactory)

---

## Troubleshooting

| Issue | Cause | Fix |
|---|---|---|
| `MSBuild not found` | Wrong path in `MSBUILD_PATH` | Verify path: `Get-Command msbuild` or check VS install dir |
| `NuGet restore failed` | Private feed auth | Add `nuget.config` with credentials or set `NUGET_CREDENTIALPROVIDERS_PATH` |
| `WinRM access denied` | Deploy user not in Remote Management Users | `Add-LocalGroupMember -Group "Remote Management Users" -Member "..."` |
| `App Pool won't start` | Bad web.config injected | Check event viewer on IIS server; verify web.config file variable |
| `Robocopy exit 8+` | Permissions error on deploy path | Re-grant FullControl to deploy user on `IIS_DEPLOY_PATH` |
| `Artifactory 401` | Wrong API key | Regenerate API key in Artifactory user profile |
| `web.config not replaced` | Variable type is Variable not File | Change variable type to **File** in GitLab Settings → CI/CD |
