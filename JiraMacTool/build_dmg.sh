#!/bin/bash

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_NAME="JiraMacTool"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
VERSION=$(date +%Y%m%d_%H%M%S)
DMG_NAME="${APP_NAME}_${VERSION}.dmg"
DMG_PATH="$PROJECT_DIR/$DMG_NAME"

echo "=============================="
echo "  JiraMacTool DMG 打包工具"
echo "=============================="
echo ""

# 1. Release 编译
echo "[1/5] Release 编译..."
cd "$PROJECT_DIR"
swift build -c release 2>&1

if [ ! -f "$BUILD_DIR/$APP_NAME" ]; then
    echo "❌ 编译失败：找不到二进制文件"
    exit 1
fi
echo "✅ 编译成功"
echo ""

# 2. 清理旧的 app bundle
echo "[2/5] 创建 .app bundle..."
if [ -d "$APP_BUNDLE" ]; then
    rm -rf "$APP_BUNDLE"
fi

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 3. 复制二进制
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 4. 复制 Info.plist
PLIST_SRC="$PROJECT_DIR/Sources/JiraMacTool/Resources/Info.plist.bak"
if [ -f "$PLIST_SRC" ]; then
    cp "$PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"
else
    echo "⚠️  找不到 Info.plist，跳过"
fi

# 5. 复制图标
if [ -f "$PROJECT_DIR/icon_src.png" ]; then
    cp "$PROJECT_DIR/icon_src.png" "$APP_BUNDLE/Contents/Resources/AppIcon.png"
fi

# 6. 复制其他资源
if [ -d "$PROJECT_DIR/Sources/JiraMacTool/Resources" ]; then
    for file in "$PROJECT_DIR/Sources/JiraMacTool/Resources/"*; do
        filename=$(basename "$file")
        if [ "$filename" != "Info.plist.bak" ]; then
            cp -R "$file" "$APP_BUNDLE/Contents/Resources/"
        fi
    done
fi
echo "✅ .app bundle 创建完成"
echo ""

# 7. 清理旧 DMG
echo "[3/5] 清理旧 DMG 文件..."
find "$PROJECT_DIR" -maxdepth 1 -name "${APP_NAME}_*.dmg" -delete 2>/dev/null || true
echo "✅ 清理完成"
echo ""

# 8. 创建 DMG
echo "[4/5] 创建 DMG..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$APP_BUNDLE" \
    -ov \
    -format UDZO \
    "$DMG_PATH" 2>&1

if [ ! -f "$DMG_PATH" ]; then
    echo "❌ DMG 创建失败"
    exit 1
fi
echo "✅ DMG 创建成功"
echo ""

# 9. 显示结果
echo "[5/5] 完成"
DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
echo ""
echo "=============================="
echo "  打包成功！"
echo "=============================="
echo "文件大小: $DMG_SIZE"
echo "保存位置: $DMG_PATH"
echo "DMG_OUTPUT_PATH=$DMG_PATH"
