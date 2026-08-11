#!/bin/sh

# =====================================================
# 脚本：通过 wget 下载预定义列表中的 .ipk 文件
# 用法：sh shell/download-packages.sh
# =====================================================

# --- 配置 ---
# 定义下载目标目录（相对于脚本执行根目录）
TARGET_DIR="packages"

# --- 初始化 ---
# 清理并创建目标目录
rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"

# --- 定义需要下载的包列表 ---
# 格式: "URL 目标文件名"
# 注意：如果目标文件名留空，将使用 URL 中的原始文件名
packages_to_download="
https://homeproxy.avkiller.top/homeproxy-avkiller_all.ipk
"
# --- 下载函数 ---
download_package() {
    local url="$1"
    local filename="$2"

    # 如果没有指定文件名，从 URL 中提取
    if [ -z "$filename" ]; then
        filename=$(basename "$url")
    fi

    local target_path="$TARGET_DIR/$filename"

    # 如果文件已存在，跳过下载
    if [ -f "$target_path" ]; then
        echo "⏭️  文件已存在，跳过: $filename"
        return 0
    fi

    echo "⬇️  正在下载: $filename"
    echo "   来自: $url"

    # 执行下载，使用 wget 的常用安全选项
    if wget -q --show-progress --timeout=30 --tries=3 "$url" -O "$target_path"; then
        echo "✅ 下载成功: $filename"
        return 0
    else
        echo "❌ 下载失败: $filename"
        # 删除可能不完整的文件
        rm -f "$target_path"
        return 1
    fi
}

# --- 主执行逻辑 ---
echo "📦 开始下载预定义软件包..."
echo "📁 目标目录: $TARGET_DIR"

# 逐行读取并处理包列表
echo "$packages_to_download" | while read -r line; do
    # 跳过空行
    [ -z "$line" ] && continue

    # 提取 URL 和文件名（如果行中包含了用空格分隔的文件名）
    # 这里简化处理：整行作为 URL，文件名由 basename 自动提取
    download_package "$line"
done

echo ""
echo "📊 下载完成。$TARGET_DIR 目录内容："
ls -lh "$TARGET_DIR"/*.ipk 2>/dev/null || echo "  (没有 .ipk 文件)"

# --- 可选：验证下载的文件 ---
# 检查是否所有文件都已成功下载
echo ""
echo "✅ 脚本执行完毕。"