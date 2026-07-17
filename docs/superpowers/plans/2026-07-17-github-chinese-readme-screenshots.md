# GitHub Chinese README and Screenshots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the public RDGDesk GitHub landing page Chinese by default, retain a complete English page, and show real sanitized application screenshots.

**Architecture:** Documentation remains static GitHub Markdown: `README.md` is Simplified Chinese and `README.en.md` is English, with symmetric language links and shared images under `docs/images/`. Screenshots come from the real app launched with an isolated Core Foundation home and a temporary fictional `.rdg`; no user library or credential data is opened. GitHub metadata is updated only after local verification passes.

**Tech Stack:** GitHub Markdown, Swift/SwiftUI macOS app, macOS `screencapture`/`sips`, Vision OCR, Git, GitHub CLI.

## Global Constraints

- `README.md` is the default Simplified Chinese landing page; `README.en.md` is the complete English equivalent.
- Both README files begin with `简体中文 | English` language links.
- Use real application windows, not generated interface mockups.
- Never open or publish the user's real `.rdg`, server names, IP addresses, ports, usernames, passwords, certificate fingerprints, or logs.
- Screenshot data is limited to `rdp.example.test` and RFC 5737 address `198.51.100.57`.
- Do not capture the global-credentials detail page because Keychain is user-scoped even when the app configuration home is isolated; use the safe certificate/privacy page instead.
- `LICENSE`, `TRADEMARKS.md`, and `THIRD_PARTY_NOTICES.md` remain authoritative English legal texts.
- Do not add a tracked demo `.rdg`; the temporary screenshot fixture lives only under `/private/tmp`.
- No application feature or production behavior changes are permitted.

---

### Task 1: Capture sanitized real application screenshots

**Files:**
- Create: `docs/images/rdgdesk-main.png`
- Create: `docs/images/rdgdesk-settings.png`
- Create: `docs/images/rdgdesk-security.png`
- Create: `docs/images/rdgdesk-connection.png`
- Temporary only: `/private/tmp/rdgdesk-readme-demo.rdg`
- Temporary only: `/private/tmp/rdgdesk-window-id.swift`
- Temporary only: `/private/tmp/rdgdesk-ocr.swift`

**Interfaces:**
- Consumes: the existing `Rdc` executable, `.rdg` importer, settings window, and connection diagnostics.
- Produces: four sanitized PNG paths referenced by both README files.

- [ ] **Step 1: Build the current app without changing source**

Run:

```bash
RDC_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/build.sh
```

Expected: exit 0 and `.build/debug/Rdc` exists.

- [ ] **Step 2: Create the untracked fictional screenshot fixture**

Use `apply_patch` to create `/private/tmp/rdgdesk-readme-demo.rdg` with exactly:

```xml
<?xml version="1.0" encoding="utf-8"?>
<RDCMan programVersion="2.92" schemaVersion="3">
  <file>
    <properties>
      <expanded>True</expanded>
      <name>RDGDesk 演示资源库</name>
    </properties>
    <group>
      <properties>
        <expanded>True</expanded>
        <name>演示环境</name>
      </properties>
      <group>
        <properties>
          <expanded>True</expanded>
          <name>业务服务器</name>
        </properties>
        <server>
          <properties>
            <displayName>应用服务器</displayName>
            <name>rdp.example.test</name>
          </properties>
        </server>
        <server>
          <properties>
            <displayName>测试服务器</displayName>
            <name>198.51.100.57</name>
          </properties>
        </server>
      </group>
    </group>
  </file>
</RDCMan>
```

Run:

```bash
rg -n "RDGDesk 演示资源库|rdp\.example\.test|198\.51\.100\.57" /private/tmp/rdgdesk-readme-demo.rdg
```

Expected: exactly the fictional library name and two allowed addresses; no credential elements.

- [ ] **Step 3: Launch with isolated configuration state**

Create `/private/tmp/rdgdesk-readme-home`, then launch the built executable with:

```bash
env CFFIXED_USER_HOME=/private/tmp/rdgdesk-readme-home \
  DYLD_LIBRARY_PATH="$PWD/.build/vendor/freerdp-prefix/lib" \
  .build/debug/Rdc
```

Expected: a fresh RDGDesk window with no restored library. Use the app's Import action to open `/private/tmp/rdgdesk-readme-demo.rdg`. Do not open the user's Downloads folder or existing application-support directory.

- [ ] **Step 4: Create a deterministic window-ID helper**

Use `apply_patch` to create `/private/tmp/rdgdesk-window-id.swift`:

```swift
import CoreGraphics
import Darwin

let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
) as? [[String: Any]] ?? []

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    guard layer == 0, owner == "Rdc" || owner == "RDGDesk" else { continue }
    if let number = window[kCGWindowNumber as String] as? Int {
        print(number)
        exit(0)
    }
}

fputs("RDGDesk window not found\n", stderr)
exit(1)
```

Run:

```bash
SWIFT_MODULECACHE_PATH=/private/tmp/rdgdesk-swift-cache \
CLANG_MODULE_CACHE_PATH=/private/tmp/rdgdesk-clang-cache \
swift /private/tmp/rdgdesk-window-id.swift
```

Expected: one numeric on-screen window ID.

- [ ] **Step 5: Capture the four approved states**

Use Computer Use to keep the RDGDesk window at a consistent size and capture these states in order:

1. Imported fictional library with “应用服务器” selected and the neutral disconnected canvas → `rdgdesk-main.png`.
2. `设置… > 通用` with the settings navigation visible → `rdgdesk-settings.png`.
3. `设置… > 证书` showing only the empty isolated certificate state → `rdgdesk-security.png`.
4. Close settings, attempt `rdp.example.test` with a one-time fictional username `demo-user` and password `not-a-real-password`, then capture the sanitized DNS/connection diagnostic → `rdgdesk-connection.png`.

For each state, make the target window frontmost, calculate `window_id` by running `/private/tmp/rdgdesk-window-id.swift`, and run:

```bash
screencapture -x -l "$window_id" "docs/images/$output_name"
sips --resampleWidth 1600 "docs/images/$output_name"
```

Expected: four non-empty PNG files, each at most 1600 pixels wide. Never select `全局凭据` or `凭据覆盖` while capturing.

- [ ] **Step 6: OCR and visually review every screenshot**

Use `apply_patch` to create `/private/tmp/rdgdesk-ocr.swift`:

```swift
import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count == 2,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Unable to load image\n", stderr)
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
request.recognitionLanguages = ["zh-Hans", "en-US"]
try VNImageRequestHandler(cgImage: cgImage).perform([request])
for result in request.results ?? [] {
    if let text = result.topCandidates(1).first?.string { print(text) }
}
```

Run OCR on all four files and review the full output. Then run:

```bash
for image in docs/images/*.png; do
  SWIFT_MODULECACHE_PATH=/private/tmp/rdgdesk-swift-cache \
  CLANG_MODULE_CACHE_PATH=/private/tmp/rdgdesk-clang-cache \
  swift /private/tmp/rdgdesk-ocr.swift "$image"
done | rg -n "([0-9]{1,3}\.){3}[0-9]{1,3}|temp2|q6id|svip|密码|password"
```

Expected: any IP match is only `198.51.100.57`; the connection screenshot may contain the generic word “密码” but no password value; none of `temp2`, `q6id`, or `svip` appears. Use `view_image` on each PNG and reject any image containing personal or real-server data.

- [ ] **Step 7: Commit screenshot assets**

Run:

```bash
git add docs/images/rdgdesk-main.png docs/images/rdgdesk-settings.png docs/images/rdgdesk-security.png docs/images/rdgdesk-connection.png
git commit -m "docs: add sanitized RDGDesk interface screenshots"
```

Expected: one commit containing only the four PNG files.

---

### Task 2: Publish Chinese default and English README

**Files:**
- Modify: `README.md`
- Create: `README.en.md`

**Interfaces:**
- Consumes: the four image paths from Task 1.
- Produces: symmetric Chinese and English landing pages with stable shared image links.

- [ ] **Step 1: Preserve the existing English content**

Use `apply_patch` to create `README.en.md` from the complete current `README.md` content. Directly below `# RDGDesk`, add:

```markdown
[简体中文](README.md) | **English**
```

After the opening target warning, add:

```markdown
## Interface preview

![RDGDesk library and remote desktop](docs/images/rdgdesk-main.png)

| General settings | Certificate management | Connection diagnostics |
| --- | --- | --- |
| ![General settings](docs/images/rdgdesk-settings.png) | ![Certificate management](docs/images/rdgdesk-security.png) | ![Connection diagnostics](docs/images/rdgdesk-connection.png) |
```

Expected: all original English sections and commands remain present.

- [ ] **Step 2: Replace the default README with complete Simplified Chinese copy**

Use `apply_patch` to make `README.md` use these exact headings in this order:

```markdown
# RDGDesk

**简体中文** | [English](README.en.md)

RDGDesk 是一款独立开发的原生 macOS 远程桌面客户端，兼容 Microsoft Remote Desktop Connection Manager（RDCMan）导出的 `.rdg` 资源库，并使用内置 FreeRDP 建立远程会话。

> 当前支持搭载 Apple 芯片、运行 macOS 26 或更高版本的 Mac。项目仍在积极开发中；用于关键系统前，请先阅读安全模型并在非生产环境中完成测试。

## 界面预览
## 现有功能
## 运行应用
## 创建自用安装包
## 开发与验证
## 项目结构
## 安全
## 兼容性与商标
## 许可证与第三方软件
```

Use the same four-image Markdown block as the English page, with Chinese alt text and column labels `通用设置`、`证书管理`、`连接诊断`. Translate every existing paragraph and bullet accurately; preserve all code blocks, environment-variable names, filenames, paths, security limits, credential-resolution order, and compatibility disclaimers verbatim where they are technical identifiers.

Expected: the Chinese page contains every capability, command, security warning, project path, and legal link from the English page; no English prose remains except product names and technical identifiers.

- [ ] **Step 3: Verify language symmetry and local links**

Run:

```bash
rg -n "简体中文.*English|docs/images/rdgdesk-(main|settings|security|connection)\.png" README.md README.en.md
rg -n "scripts/(bootstrap-freerdp|run|package-app|test|test-bootstrap-freerdp|build)\.sh" README.md README.en.md
test -f LICENSE
test -f SECURITY.md
test -f TRADEMARKS.md
test -f THIRD_PARTY_NOTICES.md
git diff --check
```

Expected: both README files contain language navigation, all four images, and the same script references; every linked local legal/security file exists; `git diff --check` exits 0.

- [ ] **Step 4: Commit bilingual documentation**

Run:

```bash
git add README.md README.en.md
git commit -m "docs: make Chinese the default GitHub language"
```

Expected: one commit containing only the two README files.

---

### Task 3: Run privacy and project verification

**Files:**
- Verify only: repository history, README files, screenshot assets, existing tests.

**Interfaces:**
- Consumes: screenshot and README commits from Tasks 1 and 2.
- Produces: evidence that public content is functional and sanitized.

- [ ] **Step 1: Verify tracked `.rdg` scope and sensitive-name absence**

Run:

```bash
git ls-files '*.rdg'
git grep -n -i -E 'temp2|q6id|svip|43\.139|106\.54|118\.89' -- . ':(exclude)docs/superpowers/**'
```

Expected: only `Tests/RdcCoreTests/Fixtures/minimal-rdcman.rdg` is tracked; the sensitive-name search has no matches.

- [ ] **Step 2: Run repository hygiene and security checks**

Run:

```bash
git diff --check
bash -n scripts/*.sh
gitleaks git --redact --no-banner
```

Expected: all commands exit 0 and gitleaks reports no leaks.

- [ ] **Step 3: Run the existing test suite**

Run:

```bash
./scripts/test.sh --disable-sandbox
```

Expected: the established suite completes with 0 failures; opt-in private/real-server tests remain skipped when their environment variables are absent.

- [ ] **Step 4: Confirm the working tree contains only intended plan-state changes**

Run:

```bash
git status --short --branch
git log -5 --oneline
```

Expected: `main` is ahead of `origin/main` only by the design, plan, screenshot, and bilingual-documentation commits, with no uncommitted files.

---

### Task 4: Publish Chinese GitHub metadata and verify the remote

**Files:**
- Remote metadata only: `layhenry/RDGDesk` description.

**Interfaces:**
- Consumes: verified local `main` from Task 3.
- Produces: public Chinese-first GitHub repository with English support.

- [ ] **Step 1: Update the repository description**

Run:

```bash
gh repo edit layhenry/RDGDesk --description "原生 macOS 远程桌面客户端，兼容 RDCMan .rdg 资源库，基于 FreeRDP"
```

Expected: exit 0.

- [ ] **Step 2: Push the verified commits**

Run:

```bash
git push origin main
```

Expected: `main -> main` succeeds on `https://github.com/layhenry/RDGDesk.git`.

- [ ] **Step 3: Verify public metadata, README, image paths, and remote SHA**

Run:

```bash
gh repo view layhenry/RDGDesk --json url,visibility,description,defaultBranchRef
gh api repos/layhenry/RDGDesk/readme --jq '.name + " " + .html_url'
gh api 'repos/layhenry/RDGDesk/git/trees/main?recursive=1' --jq '.tree[].path | select(startswith("docs/images/") or endswith("README.en.md"))'
git ls-remote origin refs/heads/main
git rev-parse HEAD
```

Expected: visibility is `PUBLIC`, description is the exact Chinese text from Step 1, the default README is `README.md`, all four images plus `README.en.md` are present, and remote/local SHA values match.
