#!/usr/bin/env bash
# Локальные smoke-проверки: собирают все SPM-пакеты и прогоняют executable-таргеты,
# которые играют роль мини-test-runner'а в окружении без Xcode (CLT-only).
# Для полноценного XCTest нужно установить Xcode и запустить `xcodebuild test`.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▶ build all packages"
swift build

echo "▶ run Core smoke"
(cd Packages/Core && swift run CoreSmoke)

echo "▶ run MockData smoke"
(cd Packages/MockData && swift run MockDataSmoke)

echo "▶ run Secrets smoke"
(cd Packages/Secrets && swift run SecretsSmoke)

echo "▶ run AppShell smoke"
(cd Packages/AppShell && swift run AppShellSmoke)

echo "▶ run MailTransport perf smoke (B10: FETCH 1000 headers ≤ 2s)"
(cd Packages/MailTransport && swift run IMAPPerfSmoke)

echo "✅ all smoke checks passed"
