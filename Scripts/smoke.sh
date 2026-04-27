#!/usr/bin/env bash
# Локальные smoke-проверки: собирают все SPM-пакеты и прогоняют executable-таргеты,
# которые играют роль мини-test-runner'а в окружении без Xcode (CLT-only).
# Для полноценного XCTest нужно установить Xcode и запустить `xcodebuild test`.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▶ build all packages"
swift build

echo "▶ build MailAi.app (xcodebuild)"
if command -v xcodebuild >/dev/null 2>&1 && [ -d "$ROOT/MailAi.xcodeproj" ]; then
  if xcodebuild -project MailAi.xcodeproj -scheme MailAi -destination 'platform=macOS' build > /tmp/xcb.log 2>&1; then
    echo "✓ MailAi.app собран"
  else
    tail -50 /tmp/xcb.log
    exit 1
  fi
else
  echo "⚠ xcodebuild недоступен или MailAi.xcodeproj отсутствует — пропускаем сборку app-таргета"
fi

echo "▶ lint theming & Dynamic Type (A9)"
"$ROOT/Scripts/lint-theming.sh"

echo "▶ swiftlint --strict"
if command -v swiftlint >/dev/null 2>&1; then
  swiftlint --strict --quiet
else
  echo "⚠ swiftlint не установлен — пропускаем"
fi

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

echo "▶ run Integration smoke (C5: end-to-end + memory inv.)"
(cd Packages/AppShell && swift run IntegrationSmoke)

echo "▶ run Live-flow smoke (Live-6: LiveAccountDataProvider e2e)"
(cd Packages/AppShell && swift run LiveFlowSmoke)

echo "▶ run Actions smoke (Mail-4: delete/archive/setFlagged)"
(cd Packages/AppShell && swift run ActionsSmoke)

echo "▶ run Search smoke (Search-3: FTS5 + QueryParser)"
(cd Packages/AppShell && swift run SearchSmoke)

echo "▶ run Classifier smoke (AI-2: Classifier actor + ClassifyV1 prompt)"
(cd Packages/AI && swift run ClassifierSmoke)

echo "▶ run RuleEngine smoke (AI-4: RuleEngine CRUD + observe)"
(cd Packages/AI && swift run RuleEngineSmoke)

echo "▶ run Privacy smoke (AI-8: snippet/hash privacy invariants)"
(cd Packages/AI && swift run PrivacySmoke)

echo "▶ run RetentionGC smoke (AI-8: classification_log retention)"
(cd Packages/Storage && swift run RetentionGCSmoke)

echo "▶ run MIME smoke (SMTP-2: MIMEComposer RFC 5322/2047/QP)"
(cd Packages/MailTransport && swift run MIMESmoke)

echo "▶ run SMTPProvider smoke (SMTP-3: SendProvider + LiveSendProvider)"
(cd Packages/MailTransport && swift run SMTPProviderSmoke)

echo "▶ run IMAP APPEND smoke (SMTP-4: APPEND command formatting)"
(cd Packages/MailTransport && swift run IMAPAppendSmoke)

echo "▶ run ServerSync smoke (AI-7: серверная синхронизация Important/Unimportant)"
(cd Packages/AppShell && swift run ServerSyncSmoke)

echo "▶ run Session+IDLE smoke (Pool-4: fake IMAP, EXISTS push, cancel)"
(cd Packages/MailTransport && swift run SessionPoolIDLESmoke)

echo "▶ run SMTP end-to-end smoke (SMTP-6: fake SMTP/IMAP servers)"
(cd Packages/MailTransport && swift run SMTPEndToEndSmoke)

echo "▶ run StatusNotifications smoke (Status-3: badge + NL-фильтр)"
(cd Packages/UI && swift run StatusNotificationsSmoke)

echo "▶ render screenshots (A10: Light/Dark → Scripts/artifacts/screenshots/)"
(cd Packages/AppShell && swift run ScreenshotSmoke)

echo "✅ all smoke checks passed"
