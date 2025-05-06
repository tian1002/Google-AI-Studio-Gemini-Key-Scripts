#!/bin/bash

# --- 配置 ---
# !! 重要：请根据你的需求修改或确认要启用的 API 服务名称 !!
# 选项 1: 只启用 Generative Language API
APIS_TO_ENABLE="generativelanguage.googleapis.com"
# 选项 2: 只启用 Vertex AI API (推荐，功能更全)
#APIS_TO_ENABLE="aiplatform.googleapis.com"
# 选项 3: 同时启用两者 (如果需要)
# APIS_TO_ENABLE="generativelanguage.googleapis.com"

# --- 身份验证和权限检查提示 ---
echo "=================================================================="
echo "重要提示：请确保满足以下条件："
echo "1. 您已通过 'gcloud auth login' 使用具有足够权限的账号登录。"
echo "2. 该账号在【所有】目标项目上拥有启用API的权限。"
echo "   (例如 'roles/serviceusage.serviceUsageAdmin', 'roles/editor', 'roles/owner')"
echo "3. 您已在上面的 'APIS_TO_ENABLE' 变量中指定了【正确】的 API 服务名称。"
echo "=================================================================="
read -p "确认已满足以上条件并准备继续吗？按 Enter 继续，按 Ctrl+C 退出..."

# --- 获取活动项目列表 ---
echo "正在获取活动项目列表..."
PROJECT_IDS=$(gcloud projects list --filter="lifecycleState=ACTIVE" --format='value(project_id)')

# 检查获取项目列表是否成功以及是否为空
if [ $? -ne 0 ] || [ -z "$PROJECT_IDS" ]; then
  echo "错误：获取活动项目列表失败，或者没有找到活动项目。"
  exit 1
fi

PROJECT_COUNT=$(echo "$PROJECT_IDS" | wc -w) # 计算项目数量
echo "成功找到 $PROJECT_COUNT 个活动项目。"

# --- 用户最终确认 ---
echo "------------------------------------------------------------------"
echo "准备在以下 $PROJECT_COUNT 个项目中尝试启用 API 服务:"
echo "  $APIS_TO_ENABLE"
echo "------------------------------------------------------------------"
echo "项目列表 (仅显示前5个):"
echo "$PROJECT_IDS" | head -n 5
echo "..."
read -p "确认要为所有 $PROJECT_COUNT 个项目执行此操作吗？(输入 'yes' 确认): " CONFIRM
# 强制用户输入 'yes' 才继续，增加安全性
if [[ "$CONFIRM" != "yes" ]]; then
    echo "操作已取消。"
    exit 0
fi

# --- 循环遍历项目并启用 API ---
SUCCESS_COUNT=0                   # 成功计数
FAILURE_COUNT=0                   # 失败计数
ALREADY_ENABLED_COUNT=0           # 已启用计数 (粗略估计)
CURRENT_PROJECT_NUM=0             # 当前处理的项目编号

echo "开始批量启用 API..."
for PROJECT_ID in $PROJECT_IDS; do
    CURRENT_PROJECT_NUM=$((CURRENT_PROJECT_NUM + 1))
    echo "-------------------------------------"
    echo "($CURRENT_PROJECT_NUM/$PROJECT_COUNT) 正在处理项目: $PROJECT_ID"

    # 执行启用命令，并将标准输出和标准错误合并捕获到变量中
    ENABLE_OUTPUT=$(gcloud services enable $APIS_TO_ENABLE --project="$PROJECT_ID" 2>&1)
    EXIT_CODE=$? # 获取上一个命令的退出状态码

    if [ $EXIT_CODE -eq 0 ]; then
        # 退出码为 0 表示命令成功（可能服务已启用，也可能是本次成功启用）
        echo "  成功：在项目 $PROJECT_ID 中已启用或成功启用了 API: $APIS_TO_ENABLE"
        # 尝试根据输出判断是否是“已经启用”的情况 (gcloud的输出可能会变)
        if echo "$ENABLE_OUTPUT" | grep -q -i "already enabled"; then
             ((ALREADY_ENABLED_COUNT++))
        fi
        ((SUCCESS_COUNT++))
    else
        # 退出码非 0 表示命令失败
        echo "  错误：在项目 $PROJECT_ID 中启用 API 失败 (退出码: $EXIT_CODE)。"
        echo "    错误详情: $ENABLE_OUTPUT" # 显示 gcloud 的错误输出
        # 根据常见的错误信息给出提示
        if echo "$ENABLE_OUTPUT" | grep -q -i "permission denied" || echo "$ENABLE_OUTPUT" | grep -q -i "caller does not have permission"; then
            echo "    提示：请检查您在此项目上的 'serviceusage.services.enable' 权限。"
        elif echo "$ENABLE_OUTPUT" | grep -q -i "billing account" || echo "$ENABLE_OUTPUT" | grep -q -i "activate billing"; then
            echo "    提示：此 API 可能需要有效的结算帐号与项目关联并启用结算。"
        elif echo "$ENABLE_OUTPUT" | grep -q -i "must be enabled"; then
             # 检查是否有依赖 API 未启用的情况
             DEPENDENCY=$(echo "$ENABLE_OUTPUT" | grep -o -E '[a-zA-Z0-9.-]+\.googleapis\.com must be enabled')
             echo "    提示：可能需要先启用依赖的 API: $DEPENDENCY"
        fi
        ((FAILURE_COUNT++))
    fi
done

# --- 输出总结信息 ---
echo "====================================="
echo "批量 API 启用过程完成。"
echo "处理的项目总数: $PROJECT_COUNT"
echo "成功启用 (或之前已启用) 的项目数: $SUCCESS_COUNT"
# echo "其中先前已启用的项目数 (基于输出的粗略估计): $ALREADY_ENABLED_COUNT" # 可选的更详细信息
echo "启用失败的项目数: $FAILURE_COUNT"
echo "====================================="
if [ $FAILURE_COUNT -gt 0 ]; then
    echo "重要提示：有 $FAILURE_COUNT 个项目未能成功启用 API，请检查上面日志中的错误详情和对应的项目权限/设置。"
fi
echo "重要提示：API 服务启用后，如果 API 本身有费用，请确保项目也已经正确关联结算账号并启用了结算。"

exit 0
