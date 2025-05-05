#!/bin/bash

# --- 配置 ---
# 1. 设置项目 ID 的前缀 (必须符合 GCP 项目 ID 命名规则)
#    现在会自动生成随机前缀
#    生成规则：1个随机小写字母 + 7个随机小写字母或数字
FIRST_CHAR=$(tr -dc 'a-z' < /dev/urandom | head -c 1)
REST_CHARS=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 7) # 7 = 8 (总长度) - 1 (首字母)
PROJECT_ID_PREFIX="${FIRST_CHAR}${REST_CHARS}"
echo "使用随机生成的项目前缀: $PROJECT_ID_PREFIX" # 显示生成的前缀

# 2. 设置要创建的项目数量
NUM_PROJECTS=20

# 3. 结算账号 ID - 设置为空，因为你不需要这个参数
BILLING_ACCOUNT_ID="" # <--- 保持为空 ""

# 4. (可选) 设置要将项目创建在哪个组织或文件夹下
#    使用组织 ID (运行 `gcloud organizations list`) 或文件夹 ID (运行 `gcloud resource-manager folders list`)
PARENT_RESOURCE_ID="" # <--- 修改这里 (例如 "organizations/123...") 或 "folders/123...") 或留空 ""
# --- 配置结束 ---

# --- 检查配置 (现在不需要检查 PROJECT_ID_PREFIX 是否为空，因为它总是会生成) ---
# (原始检查已移除)

# --- 构建可选参数 ---
GCLOUD_ARGS=() # 初始化一个空数组来存储参数

# 注意：不再添加 --billing-account 参数，因为 BILLING_ACCOUNT_ID 为空

# 处理组织或文件夹参数（如果设置了）
if [[ -n "$PARENT_RESOURCE_ID" ]]; then
  if [[ "$PARENT_RESOURCE_ID" == organizations/* ]]; then
    GCLOUD_ARGS+=( "--organization=${PARENT_RESOURCE_ID#organizations/}" )
  elif [[ "$PARENT_RESOURCE_ID" == folders/* ]]; then
      GCLOUD_ARGS+=( "--folder=${PARENT_RESOURCE_ID#folders/}" )
  else
    echo "警告：PARENT_RESOURCE_ID 格式无法识别 ('$PARENT_RESOURCE_ID')。期望 'organizations/ID' 或 'folders/ID'。将忽略此参数。"
  fi
fi

echo "将要创建 $NUM_PROJECTS 个项目，随机前缀为 '$PROJECT_ID_PREFIX'..."
if [[ ${#GCLOUD_ARGS[@]} -gt 0 ]]; then
    echo "附加参数: ${GCLOUD_ARGS[*]}"
fi
echo "注意：项目创建时不会关联结算账号。"
read -p "确认开始吗? (y/N): " confirm && [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]] || exit 1


# --- 执行循环创建 ---
for i in $(seq 1 $NUM_PROJECTS)
do
  # 项目 ID 规则: 6-30 字符, 小写字母/数字/连字符, 必须以字母开头, 不能以连字符结尾
  # 我们的格式: prefix-i (例如 randompfx-1, randompfx-20), 长度一般是 8 + 1 + (1 or 2) = 10-11, 符合规则
  PROJECT_ID="${PROJECT_ID_PREFIX}-${i}"

  echo "-----------------------------------------------------"
  echo "正在创建项目: $PROJECT_ID ..."

  # 使用标准的 gcloud projects create 命令
  gcloud projects create "$PROJECT_ID" "${GCLOUD_ARGS[@]}"

  if [ $? -eq 0 ]; then
    echo "项目 $PROJECT_ID 创建请求已提交。"
  else
    echo "错误：创建项目 $PROJECT_ID 时遇到问题。请检查上面的错误消息。"
    # 可以在这里添加错误处理逻辑，比如退出脚本或记录失败的项目
    # exit 1 # 如果希望在第一个错误时停止，取消注释此行
  fi
  echo "-----------------------------------------------------"
  # sleep 1 # 可选延迟, 在大量创建时可能有助于避免 API 速率限制
done

echo "脚本执行完毕。请注意，这些项目尚未关联结算账号，可能需要稍后手动关联。"
echo "你可以使用 'gcloud projects list --filter=\"name:${PROJECT_ID_PREFIX}-\" --format='value(projectId)' 查看本次创建的项目。"
