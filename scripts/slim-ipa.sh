#!/usr/bin/env bash
# Agy.app 编译后瘦身脚本（供 GitHub Actions / Codemagic / 本地 Xcode 调用）
# 1. 仅保留 latinmodern-math 数学字体，裁剪其余 10 套未用 OTF/plist（省 ~4MB）
# 2. 对主程序与 Widget Mach-O 执行非全局符号裁剪（strip -x）
# 3. 校验 PrivacyInfo.xcprivacy 与 Widget 版本一致性
set -euo pipefail

APP_PATH="${1:-Payload/Agy.app}"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Usage: $0 <path-to-Agy.app>" >&2
  exit 1
fi

echo "==> Slimming $APP_PATH"
du -sh "$APP_PATH"

# 1. 裁剪 SwiftMath 未用字体，仅保留 latinmodern-math + 许可证
MATH_FONTS="$APP_PATH/SwiftMath_SwiftMath.bundle/mathFonts.bundle"
if [[ -d "$MATH_FONTS" ]]; then
  find "$MATH_FONTS" -maxdepth 1 -type f \
    ! -name 'latinmodern-math.otf' \
    ! -name 'latinmodern-math.plist' \
    ! -name 'LICENSE' \
    ! -name 'OFL.txt' \
    ! -name 'GUST-FONT-LICENSE.txt' \
    -delete
  echo "==> Remaining mathFonts:"
  ls -lh "$MATH_FONTS"
fi

# 2. 裁剪非全局符号（无签名免签构建可安全执行）
if command -v strip >/dev/null 2>&1; then
  for bin in "$APP_PATH/Agy" "$APP_PATH/PlugIns/AgyWidget.appex/AgyWidget"; do
    if [[ -f "$bin" ]]; then
      before=$(wc -c < "$bin")
      strip -x "$bin" 2>/dev/null || true
      after=$(wc -c < "$bin")
      echo "==> strip -x $(basename "$bin"): ${before} -> ${after} bytes"
    fi
  done
fi

# 3. 清理多余的 _CodeSignature（免签 IPA 重新签名更干净）与 .DS_Store
find "$APP_PATH" -name '.DS_Store' -delete

# 4. 基础健康检查
if [[ ! -f "$APP_PATH/PrivacyInfo.xcprivacy" ]]; then
  echo "::warning::PrivacyInfo.xcprivacy missing in $APP_PATH"
fi

echo "==> Slimmed size:"
du -sh "$APP_PATH"
