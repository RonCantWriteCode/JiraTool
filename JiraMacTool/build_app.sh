#!/bin/bash

set -e

# 项目根目录
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_NAME="JiraMacTool"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

echo "🔨 开始编译 $APP_NAME..."

# 1. Release 编译
cd "$PROJECT_DIR"
swift build -c release

if [ ! -f "$BUILD_DIR/$APP_NAME" ]; then
    echo "❌ 编译失败：找不到二进制文件 $BUILD_DIR/$APP_NAME"
    exit 1
fi

echo "✅ 编译成功"

# 2. 清理旧的 app bundle
if [ -d "$APP_BUNDLE" ]; then
    echo "🗑️  删除旧的 $APP_NAME.app"
    rm -rf "$APP_BUNDLE"
fi

# 3. 创建 .app 目录结构
echo "📦 打包 $APP_NAME.app..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 4. 复制二进制文件
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 5. 复制 Info.plist
cp "$PROJECT_DIR/Sources/JiraMacTool/Resources/Info.plist.bak" "$APP_BUNDLE/Contents/Info.plist"

# 6. 复制图标
if [ -f "$PROJECT_DIR/icon_src.png" ]; then
    cp "$PROJECT_DIR/icon_src.png" "$APP_BUNDLE/Contents/Resources/AppIcon.png"
    echo "✅ 图标已复制"
else
    echo "⚠️  警告：找不到 icon_src.png，应用将没有图标"
fi

# 7. 复制其他资源（排除 Info.plist.bak）
if [ -d "$PROJECT_DIR/Sources/JiraMacTool/Resources" ]; then
    for file in "$PROJECT_DIR/Sources/JiraMacTool/Resources/"*; do
        filename=$(basename "$file")
        if [ "$filename" != "Info.plist.bak" ]; then
            cp -R "$file" "$APP_BUNDLE/Contents/Resources/"
        fi
    done
fi

# 8. 安装到 /Applications（新增或替换）
INSTALL_DIR="/Applications"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME.app"
echo ""
echo "📲 安装到 $INSTALL_DIR ..."
if [ -d "$INSTALL_PATH" ]; then
    echo "🗑️  删除旧的 $INSTALL_PATH"
    rm -rf "$INSTALL_PATH"
fi
cp -R "$APP_BUNDLE" "$INSTALL_PATH"
echo "✅ 已安装到 $INSTALL_PATH"

echo ""
echo "🎉 打包完成！"
echo "📍 位置：$APP_BUNDLE"
echo "📍 已安装：$INSTALL_PATH"
echo ""
echo "你可以通过以下方式运行："
echo "  双击 $APP_NAME.app"
echo "  或命令行：open \"$INSTALL_PATH\""
