# Excel 导出模板问题修复说明

## 🔧 问题描述

**错误信息**: `导出失败: Failed to unzip template`

**原因**: 
- 原先使用 `ditto` 命令解压 xlsx 文件
- `ditto -x -k` 会创建额外的嵌套目录层
- 导致无法正确找到 `xl/worksheets/sheet1.xml` 文件

## ✅ 修复方案

### 1. 更换解压工具
```swift
// 之前 (失败)
/usr/bin/ditto -x -k --sequesterRsrc template.xlsx tempDir

// 现在 (成功)
/usr/bin/unzip -o template.xlsx -d extractionDir
```

### 2. 智能目录查找
由于不同工具创建的 xlsx 文件结构可能略有不同，添加了自动查找逻辑：

```swift
// 先尝试直接路径
let directXlPath = extractionDir.appendingPathComponent("xl")
if fileManager.fileExists(atPath: directXlPath.path) {
    xlDir = directXlPath
} else {
    // 递归搜索 xl 目录
    // 支持嵌套结构
}
```

### 3. 更换压缩工具
```swift
// 之前
/usr/bin/ditto -c -k --sequesterRsrc --keepParent sourceDir output.xlsx

// 现在
/usr/bin/zip -r -q output.xlsx .
```

### 4. 增强错误处理
- 捕获并显示 unzip 的错误输出
- 验证关键文件是否存在
- 提供更详细的错误信息

## 📋 修复内容

### 修改的文件
- `Sources/JiraMacTool/Services/ExcelService.swift`

### 关键改进

#### 1. 解压部分
```swift
let unzipProcess = Process()
unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
unzipProcess.arguments = ["-o", templatePath, "-d", extractionDir.path]
unzipProcess.standardError = pipe  // 捕获错误信息
unzipProcess.standardOutput = Pipe()
```

#### 2. 目录查找
```swift
// 支持多种目录结构
var xlDir: URL?

// 尝试直接路径
let directXlPath = extractionDir.appendingPathComponent("xl")
if fileManager.fileExists(atPath: directXlPath.path) {
    xlDir = directXlPath
} else {
    // 递归查找
    if let enumerator = fileManager.enumerator(at: extractionDir, ...) {
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "xl" {
                xlDir = fileURL
                break
            }
        }
    }
}
```

#### 3. 压缩部分
```swift
let zipProcess = Process()
zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
zipProcess.arguments = ["-r", "-q", outputPath, "."]
zipProcess.currentDirectoryURL = zipSourceDir  // 设置工作目录
```

## 🧪 测试步骤

### 1. 重新编译
```bash
cd "/Users/wuhaopeng/Documents/synology-公司文档/008-self-code/jira-mac-Swift/JiraMacTool"
swift build
```

### 2. 运行应用
```bash
swift run JiraMacTool
```

### 3. 测试带模板导出
1. 切换到 "Excel导出" 标签
2. 设置截止日期（如：2026-04-30）
3. 点击"模板路径"的"选择..."按钮
4. 选择你的 xlsx 模板文件
5. 设置输出路径（如：/tmp/test_output.xlsx）
6. 点击"导出"按钮
7. 查看日志输出

### 4. 验证结果
```bash
# 检查文件是否生成
ls -lh /tmp/test_output.xlsx

# 打开查看
open /tmp/test_output.xlsx
```

## 🎯 预期结果

### 成功情况
```
已导出 Excel: /tmp/test_output.xlsx

邮件列表:
xxx@sinosafe.com.cn;...

通知事项:
1、TEST-001 ...
```

### 失败情况（会显示详细错误）
```
导出失败: Failed to unzip template: [具体错误信息]
```
或
```
导出失败: Template structure invalid: sheet1.xml not found
```

## 🔍 故障排查

### 问题1: 仍然提示 "Failed to unzip template"
**检查项**:
1. 模板文件是否损坏？用 Excel 打开试试
2. 模板是否是真正的 xlsx 格式？（不是 xls）
3. 查看完整错误信息（现在会显示 unzip 的输出）

**解决方法**:
```bash
# 手动测试解压
unzip -l your_template.xlsx  # 列出内容
unzip -o your_template.xlsx -d /tmp/test_extract  # 尝试解压
```

### 问题2: "Template structure invalid"
**原因**: 模板文件结构不完整

**检查模板应包含**:
```
template.xlsx
├── [Content_Types].xml
├── _rels/
│   └── .rels
└── xl/
    ├── workbook.xml
    ├── styles.xml
    ├── _rels/
    │   └── workbook.xml.rels
    └── worksheets/
        └── sheet1.xml
```

**验证方法**:
```bash
unzip -l your_template.xlsx | grep -E "xl|sheet1"
```

### 问题3: 导出成功但文件打不开
**可能原因**: 压缩时目录结构不对

**检查方法**:
```bash
# 查看生成的文件结构
unzip -l /tmp/test_output.xlsx
```

**应该看到**:
```
[Content_Types].xml
_rels/.rels
xl/workbook.xml
xl/styles.xml
xl/worksheets/sheet1.xml
...
```

## 📊 技术对比

| 项目 | 之前 (ditto) | 现在 (unzip/zip) |
|------|-------------|-----------------|
| 解压命令 | `ditto -x -k` | `unzip -o` |
| 压缩命令 | `ditto -c -k` | `zip -r -q` |
| 目录处理 | 创建嵌套目录 | 保持原始结构 |
| 错误信息 | 简单 | 详细（包含命令输出）|
| 兼容性 | 有问题 | 稳定可靠 |

## 🎉 总结

修复后的 Excel 导出功能：
- ✅ 使用标准的 `unzip` 和 `zip` 命令
- ✅ 自动适应不同的目录结构
- ✅ 提供详细的错误信息
- ✅ 更好的兼容性和稳定性

现在应该可以正常处理你的 xlsx 模板文件了！

## 📞 还有问题？

如果仍然遇到问题，请提供：
1. 完整的错误日志
2. 模板文件的结构：`unzip -l your_template.xlsx`
3. 模板文件是否可以正常在 Excel 中打开
