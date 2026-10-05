<#
.SYNOPSIS
  Google "send-zhong" (google.com -> google.com.hk) node checker for Clash Verge / Mihomo.

.DESCRIPTION
  Spins up an isolated mihomo instance and walks every node in a subscription
  (URL, local file, or the currently active Clash Verge profile), issuing a
  fresh cookie-free request to https://www.google.com/ for each node.
  The first-hop "Location" header decides the verdict:
    SENDZHONG  = 302 to google.com.hk
    OK         = 200 / consent.google.com
    OTHER-CC   = 302 to google.com.xx (xx != hk)
    DEAD       = node unreachable / timeout

  The isolated instance uses its own ports and never touches your live Clash.
  Your original node selection is never modified.

.EXAMPLE
  .\check-sendzhong.ps1 -SubscriptionUrl "https://example.com/sub"

.EXAMPLE
  .\check-sendzhong.ps1                 # auto-detect Clash Verge current profile

.EXAMPLE
  .\check-sendzhong.ps1 -Regions 日本,美国 -Format md
#>

[CmdletBinding()]
param(
  [string]$SubscriptionUrl = "",
  [string]$ProfilePath = "",
  [string]$MihomoPath = "",
  [string[]]$Regions = @(),
  [string[]]$ExcludeRegions = @("香港"),
  [string]$Output = "",
  [ValidateSet("txt","md")][string]$Format = "txt",
  [int]$TimeoutSec = 12,
  [int]$DelayMs = 350,
  [int]$MixedPort = 0,
  [int]$CtrlPort = 0,
  [switch]$KeepInstance
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Net.Http

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$STAMP = Get-Date -Format "yyyyMMdd_HHmmss"
$INSTANCE = Join-Path $ScriptDir "instance_$STAMP"
$HK_FLAG = [char]::ConvertFromUtf32(0x1F1ED) + [char]::ConvertFromUtf32(0x1F1F0)

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

function Get-FreePort([int]$start) {
  $p = $start
  while (Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue) { $p++ }
  return $p
}

# ---------- 1) locate mihomo kernel ----------
if (-not $MihomoPath) {
  $candidates = @(
    "D:\Program Files\Clash Verge\verge-mihomo.exe",
    "$env:ProgramFiles\Clash Verge\verge-mihomo.exe",
    "$env:ProgramFiles(x86)\Clash Verge\verge-mihomo.exe",
    "$env:LOCALAPPDATA\Programs\Clash Verge\verge-mihomo.exe"
  )
  foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { $MihomoPath = $c; break } }
}
if (-not $MihomoPath -or -not (Test-Path $MihomoPath)) {
  Fail "mihomo kernel not found. Specify it with -MihomoPath."
}
Write-Host "[*] kernel: $MihomoPath"

# ---------- 2) resolve subscription source ----------
if ($ProfilePath -and (Test-Path $ProfilePath)) {
  $SubType = "file"; $SubSource = (Resolve-Path $ProfilePath).Path
} elseif ($SubscriptionUrl) {
  $SubType = "http"; $SubSource = $SubscriptionUrl
} else {
  # auto-detect Clash Verge current profile
  $vergeDir = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"
  $profilesYaml = "$vergeDir\profiles.yaml"
  if (-not (Test-Path $profilesYaml)) { Fail "No subscription given and Clash Verge config not found. Use -SubscriptionUrl or -ProfilePath." }
  $raw = Get-Content $profilesYaml -Raw -Encoding UTF8
  $m = [regex]::Match($raw, 'current:\s*(\S+)')
  if (-not $m.Success) { Fail "Clash Verge profiles.yaml has no 'current'." }
  $cur = $m.Groups[1].Value
  $m2 = [regex]::Match($raw, "(?ms)- uid: $cur\s*\r?\n\s*type: \S+\s*\r?\n\s*name: [^\r\n]*\s*\r?\n\s*file: (\S+)")
  if (-not $m2.Success) { Fail "Cannot resolve current Clash Verge profile '$cur'." }
  $ProfilePath = Join-Path "$vergeDir\profiles" $m2.Groups[1].Value
  if (-not (Test-Path $ProfilePath)) { Fail "Profile file not found: $ProfilePath" }
  $SubType = "file"; $SubSource = $ProfilePath
}
Write-Host "[*] subscription: $SubType -> $SubSource"

# ---------- 3) build isolated config ----------
if ($MixedPort -eq 0) { $MixedPort = Get-FreePort 17890 }
if ($CtrlPort -eq 0) { $CtrlPort = Get-FreePort 19090 }
$SECRET = "sendzhong"

# For http subscriptions, download the Clash YAML ourselves (send a Clash user-agent).
# For file subscriptions, copy into the instance dir (mihomo SAFE_PATHS requires the
# provider file to live under the working directory).
New-Item -ItemType Directory -Force -Path $INSTANCE | Out-Null
$providerFile = Join-Path $INSTANCE "sub_provider.yaml"
if ($SubType -eq "http") {
  try {
    Invoke-WebRequest -Uri $SubSource -Headers @{ "User-Agent" = "clash-verge" } -TimeoutSec 30 -OutFile $providerFile -ErrorAction Stop
  } catch { Fail "failed to download subscription YAML: $($_.Exception.Message)" }
  Write-Host "[*] downloaded subscription YAML -> $providerFile"
} else {
  Copy-Item -LiteralPath $SubSource -Destination $providerFile -Force
  Write-Host "[*] copied local profile -> $providerFile"
}
# sanity check the YAML actually has a proxies section
$firstLine = (Get-Content $providerFile -TotalCount 1 -Encoding UTF8)
$all = Get-Content $providerFile -Raw -Encoding UTF8
if ($all -notmatch '(?m)^proxies:') {
  if ($firstLine -notmatch ':') {
    Fail "subscription is not Clash YAML (looks like a base64 URI list). Provide a YAML/Clash-formatted subscription or file."
  }
}

$provPath = $providerFile -replace '\\', '/'
$provBlock = @()
$provBlock += "proxy-providers:"
$provBlock += "  sub:"
$provBlock += "    type: file"
$provBlock += "    path: `"$provPath`""

$configText = @"
mixed-port: $MixedPort
allow-lan: false
mode: rule
log-level: warning
ipv6: false
external-controller: 127.0.0.1:$CtrlPort
secret: $SECRET
unified-delay: true
tcp-concurrent: true
find-process-mode: off
dns:
  enable: true
  ipv6: false
  listen: 127.0.0.1:17853
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  respect-rules: true
  default-nameserver: [223.5.5.5, 8.8.8.8]
  proxy-server-nameserver: [223.5.5.5, 8.8.8.8]
  nameserver: ['https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query']
proxy-groups:
  - name: NODES
    type: select
    use: [sub]
rules:
  - MATCH,NODES
"@

New-Item -ItemType Directory -Force -Path $INSTANCE | Out-Null
$cfgLines = @()
$cfgLines += ($configText -split "`r?`n")
$cfgLines += $provBlock
[System.IO.File]::WriteAllLines("$INSTANCE\config.yaml", $cfgLines, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[*] isolated config: $INSTANCE\config.yaml"

# ---------- 4) start isolated instance ----------
# stop leftover test instances owning our candidate ports
foreach ($p in 17890..17899 + 19090..19099) {
  $own = (Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess
  if ($own) { try { Stop-Process -Id $own -Force -ErrorAction Stop } catch {} }
}
Start-Sleep -Milliseconds 500

$proc = Start-Process -FilePath $MihomoPath -ArgumentList "-d", "`"$INSTANCE`"", "-f", "`"$INSTANCE\config.yaml`"" -WorkingDirectory $INSTANCE -WindowStyle Hidden -PassThru -RedirectStandardOutput "$INSTANCE\mihomo.log" -RedirectStandardError "$INSTANCE\mihomo.err.log"

$CTRL = "http://127.0.0.1:$CtrlPort"
$PROXY = "http://127.0.0.1:$MixedPort"

function Ctrl([string]$method, [string]$path, [string]$jsonBody) {
  $c = New-Object System.Net.Http.HttpClient
  $c.Timeout = [TimeSpan]::FromSeconds(10)
  $c.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $SECRET)
  $req = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($method)), "$CTRL$path")
  if ($jsonBody) { $req.Content = New-Object System.Net.Http.StringContent($jsonBody, [Text.Encoding]::UTF8, "application/json") }
  try { return $c.SendAsync($req).Result.Content.ReadAsStringAsync().Result } catch { return "" } finally { $req.Dispose(); $c.Dispose() }
}
function Set-Group([string]$group, [string]$name) {
  $b = @{ name = $name } | ConvertTo-Json -Compress
  Ctrl "PUT" "/proxies/$([uri]::EscapeDataString($group))" $b | Out-Null
}
function Get-GoogleRedirect {
  $hh = New-Object System.Net.Http.HttpClientHandler
  $hh.AllowAutoRedirect = $false; $hh.UseCookies = $false
  $hh.Proxy = New-Object System.Net.WebProxy($PROXY, $false); $hh.UseProxy = $true
  $c = New-Object System.Net.Http.HttpClient($hh); $c.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  try {
    $rq = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, "https://www.google.com/")
    $rq.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36") | Out-Null
    $rq.Headers.TryAddWithoutValidation("Cache-Control", "no-cache") | Out-Null
    $r = $c.SendAsync($rq).Result
    $loc = ""; if ($r.Headers.Location) { $loc = $r.Headers.Location.ToString() }
    return [pscustomobject]@{ Status = [int]$r.StatusCode; Loc = $loc }
  } catch { return [pscustomobject]@{ Status = 0; Loc = "EXC/TIMEOUT" } } finally { $c.Dispose(); $hh.Dispose() }
}

$results = @()
try {
  $up = $false
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    try { Invoke-RestMethod "$CTRL/version" -Headers @{ Authorization = "Bearer $SECRET" } -TimeoutSec 2 | Out-Null; $up = $true; break } catch {}
  }
  if (-not $up) {
    Write-Host "ERROR: isolated instance failed to start. Kernel log:" -ForegroundColor Red
    Get-Content "$INSTANCE\mihomo.log" -ErrorAction SilentlyContinue | Select-Object -Last 8
    Get-Content "$INSTANCE\mihomo.err.log" -ErrorAction SilentlyContinue | Select-Object -Last 8
    throw "instance-up-fail"
  }
  Write-Host "[*] instance up (pid=$($proc.Id), proxy=$MixedPort, ctrl=$CtrlPort)"

  # wait for proxy provider to load nodes
  $provList = $null
  for ($i = 0; $i -lt 30; $i++) {
    $provList = (Ctrl "GET" "/providers/proxies" $null) | ConvertFrom-Json
    if ($provList -and $provList.providers.sub -and $provList.providers.sub.proxies.Count -gt 0) { break }
    Start-Sleep -Seconds 1
  }
  if (-not $provList -or -not $provList.providers.sub -or $provList.providers.sub.proxies.Count -eq 0) {
    throw "no-nodes"
  }

  # ---------- 5) enumerate nodes ----------
  $realTypes = @('Vmess','Vless','Trojan','Shadowsocks','Hysteria','Hysteria2','Tuic','WireGuard','Socks5','Http','Snell','Ssh','AnyTLS','Mieru')
  $infoKw = @('剩余','流量','到期','官网','订阅','网址','群','客服','http')
  $nodes = @()
  foreach ($p in $provList.providers.sub.proxies) {
    $name = $p.name
    if (-not $name) { continue }
    if ($p.type -notin $realTypes) { continue }
    $isInfo = $false
    foreach ($kw in $infoKw) { if ($name -match [regex]::Escape($kw)) { $isInfo = $true; break } }
    if ($isInfo) { continue }
    if ($name.Contains($HK_FLAG) -or ($ExcludeRegions | Where-Object { $_ -and ($name -match [regex]::Escape($_)) })) { continue }
    if ($Regions.Count -gt 0) {
      $hit = $false
      foreach ($kw in $Regions) { if ($kw -and ($name -match [regex]::Escape($kw))) { $hit = $true; break } }
      if (-not $hit) { continue }
    }
    $nodes += $name
  }
  Write-Host "[*] nodes to test: $($nodes.Count)"
  if ($nodes.Count -eq 0) { throw "no-nodes-after-filter" }

  # ---------- 6) test each node ----------
  # Use the proxied google.com request itself as the liveness + send-zhong test
  # (proxy-provider nodes don't support the controller /delay endpoint).
  $idx = 0
  foreach ($n in $nodes) {
    $idx++
    # switch node, then verify the switch took effect (retry once)
    $swOk = $false
    foreach ($try in 1..2) {
      Set-Group "NODES" $n
      Start-Sleep -Milliseconds $DelayMs
      $now = ((Ctrl "GET" "/proxies/NODES" $null) | ConvertFrom-Json).now
      if ($now -eq $n) { $swOk = $true; break }
      Start-Sleep -Milliseconds 500
    }
    if (-not $swOk) {
      $results += [pscustomobject]@{ Node = $n; Delay = "SWFAIL"; Status = "-"; Loc = "" }
      Write-Host "[$idx/$($nodes.Count)] SWITCH-FAIL"
      continue
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $gr = Get-GoogleRedirect
    $sw.Stop()
    $d = [int]$sw.ElapsedMilliseconds
    if ($gr.Status -eq 0) {
      $results += [pscustomobject]@{ Node = $n; Delay = "DEAD"; Status = "-"; Loc = "" }
      Write-Host "[$idx/$($nodes.Count)] DEAD"
    } else {
      $results += [pscustomobject]@{ Node = $n; Delay = $d; Status = $gr.Status; Loc = $gr.Loc }
      $mark = if ($gr.Loc -match 'google\.com\.hk') { "SENDZHONG" } elseif ($gr.Status -eq 200 -or $gr.Loc -match 'consent\.google') { "OK" } else { "OTHER" }
      Write-Host "[$idx/$($nodes.Count)] ${d}ms  $mark"
    }
  }
} finally {
  if (-not $KeepInstance) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $INSTANCE -Recurse -Force -ErrorAction SilentlyContinue
  } else {
    Write-Host "[i] instance kept (pid=$($proc.Id), dir=$INSTANCE)"
  }
}

if ($results.Count -eq 0) {
  Fail "no results. Check your subscription and Clash Verge installation."
}

# ---------- 7) report ----------
function VerdictOf($r) {
  if ($r.Delay -eq 'DEAD' -or $r.Status -eq 0 -or $r.Status -eq "-") { return "DEAD" }
  if ($r.Loc -match 'google\.com\.hk') { return "SENDZHONG" }
  if ($r.Loc -match 'consent\.google') { return "OK" }
  if ($r.Status -eq 200) { return "OK" }
  if ($r.Loc -match 'google\.com\.[a-z]{2}') { return "OTHER-CC" }
  return "REDIR"
}

$ok = @(); $sz = @(); $other = @(); $dead = @()
foreach ($r in $results) {
  $v = VerdictOf $r
  switch ($v) {
    "OK" { $ok += $r }
    "SENDZHONG" { $sz += $r }
    "DEAD" { $dead += $r }
    default { $other += $r }
  }
}

if (-not $Output) { $Output = Join-Path $ScriptDir "report_$STAMP.$Format" }

$rep = @()
$rep += "# Google Send-Zhong Check  ($STAMP)"
$rep += "# source: $SubType"
$rep += "# nodes: $($results.Count)   OK: $($ok.Count)   SENDZHONG: $($sz.Count)   DEAD: $($dead.Count)   OTHER: $($other.Count)"
$rep += ""
if ($Format -eq "md") {
  $rep += "| Node | Delay(ms) | Status | Verdict |"
  $rep += "| --- | --- | --- | --- |"
  foreach ($r in $results) { $rep += ("| {0} | {1} | {2} | {3} |" -f $r.Node, $r.Delay, $r.Status, (VerdictOf $r)) }
} else {
  $rep += "Node`tDelay`tStatus`tVerdict`tLocation"
  foreach ($r in $results) { $rep += ("{0}`t{1}`t{2}`t{3}`t{4}" -f $r.Node, $r.Delay, $r.Status, (VerdictOf $r), $r.Loc) }
}
[System.IO.File]::WriteAllLines($Output, $rep, (New-Object System.Text.UTF8Encoding($false)))

# console summary
Write-Host ""
Write-Host "================ SUMMARY ================" -ForegroundColor Cyan
Write-Host ("OK        : {0}" -f $ok.Count) -ForegroundColor Green
Write-Host ("SENDZHONG : {0}" -f $sz.Count) -ForegroundColor Red
Write-Host ("DEAD      : {0}" -f $dead.Count) -ForegroundColor DarkGray
Write-Host ("OTHER     : {0}" -f $other.Count) -ForegroundColor Yellow
Write-Host "========================================="
if ($ok.Count -gt 0) {
  Write-Host "OK nodes:" -ForegroundColor Green
  $ok | ForEach-Object { Write-Host "  - $($_.Node)  ($($_.Delay)ms)" }
}
Write-Host ""
Write-Host "Report: $Output"
