#!/bin/bash

# --- 函数定义区域 ---

# 功能1: 创建 GCP 项目
create_gcp_projects() {
  echo "--- 开始执行 GCP 项目创建脚本 ---"
  echo ""

  # --- 变量定义 (来自您提供的脚本) ---

  # 1. 自动生成项目 ID 的前缀 (1个小写字母 + 9个小写字母或数字)
  #    确保符合规则: 小写字母开头, 字母/数字/连字符, 6-30字符
  FIRST_CHAR=$(head /dev/urandom | tr -dc 'a-z' | head -c 1)
  REST_CHARS=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 9)
  PROJECT_ID_PREFIX="${FIRST_CHAR}${REST_CHARS}"
  echo "本次运行将使用的随机项目 ID 前缀: ${PROJECT_ID_PREFIX}"

  # 2. 自动获取你的数字组织 ID
  echo "正在尝试自动获取组织 ID..."
  ORGANIZATION_ID=$(gcloud organizations list --format="value(ID)" --limit=1 2>/dev/null)

  if [[ -z "$ORGANIZATION_ID" ]]; then
    echo "错误：无法自动获取组织 ID。"
    echo "请确保您已使用 'gcloud auth login' 和 'gcloud auth application-default login' 登录，"
    echo "并且您的账户有权列出组织。或者，请在脚本中手动设置 ORGANIZATION_ID。"
    echo "项目创建中止。"
    return 1 # 返回到主菜单
  else
    echo "成功获取组织 ID: ${ORGANIZATION_ID}"
  fi

  # 3. (可选) 设置你的结算账号 ID (格式: 012345-67890A-BCDEF1)
  BILLING_ACCOUNT_ID="YOUR_BILLING_ACCOUNT_ID" # <--- 如果需要，请修改这里

  # 4. 运行时询问要创建的项目数量
  while true; do
    read -p "您想创建多少个项目? " NUM_PROJECTS
    if [[ "$NUM_PROJECTS" =~ ^[1-9][0-9]*$ ]]; then
      break
    else
      echo "无效输入。请输入一个正整数。"
    fi
  done

  PARENT_RESOURCE="--organization=${ORGANIZATION_ID}"
  # 如果你想在文件夹下创建，请取消注释下一行并设置 FOLDER_ID
  # FOLDER_ID="YOUR_FOLDER_ID"
  # PARENT_RESOURCE="--folder=${FOLDER_ID}"
  # if [[ "$PARENT_RESOURCE" == "--folder=YOUR_FOLDER_ID" && "$FOLDER_ID" == "YOUR_FOLDER_ID" ]]; then
  #   echo "错误：如果您选择在文件夹下创建项目，请设置有效的 FOLDER_ID。"
  #   echo "项目创建中止。"
  #   return 1
  # fi

  LINK_BILLING=false
  if [[ -n "$BILLING_ACCOUNT_ID" && "$BILLING_ACCOUNT_ID" != "YOUR_BILLING_ACCOUNT_ID" ]]; then
      LINK_BILLING=true
      echo "配置了结算账号 ID: ${BILLING_ACCOUNT_ID}，将在创建后尝试链接。"
  else
      echo "未配置有效的结算账号 ID，将跳过自动链接步骤。"
  fi

  echo "准备创建 ${NUM_PROJECTS} 个项目，前缀为 '${PROJECT_ID_PREFIX}'，父资源为 '${PARENT_RESOURCE}'..."
  echo "-----------------------------------------------------"

  for i in $(seq 1 ${NUM_PROJECTS})
  do
    PROJECT_ID_SUFFIX=$(printf "%03d" ${i})
    FULL_PROJECT_ID="${PROJECT_ID_PREFIX}-${PROJECT_ID_SUFFIX}"
    FULL_PROJECT_ID=${FULL_PROJECT_ID:0:30}

    echo ""
    echo "--> 正在创建项目 #${i} (总共 ${NUM_PROJECTS} 个): ${FULL_PROJECT_ID} ..."

    if gcloud projects create ${FULL_PROJECT_ID} ${PARENT_RESOURCE} --name="${FULL_PROJECT_ID}-friendly-name"; then
      echo "    项目 ${FULL_PROJECT_ID} 创建成功。"
      if ${LINK_BILLING}; then
        echo "    正在链接结算账号 ${BILLING_ACCOUNT_ID} 到 ${FULL_PROJECT_ID}..."
        if gcloud beta billing projects link ${FULL_PROJECT_ID} --billing-account=${BILLING_ACCOUNT_ID}; then
          echo "    成功链接结算账号到 ${FULL_PROJECT_ID}。"
        else
          echo "    警告：链接结算账号到 ${FULL_PROJECT_ID} 失败。请稍后手动操作。"
          echo "    失败的项目ID已记录: ${FULL_PROJECT_ID}" >> failed_billing_links.txt
        fi
      fi
    else
      echo "    错误：创建项目 ${FULL_PROJECT_ID} 失败。"
      echo "失败的项目ID尝试: ${FULL_PROJECT_ID}" >> failed_project_creations.txt
    fi

    if [[ $i -lt $NUM_PROJECTS ]]; then
        echo "    延时 5 秒以避免API速率限制..."
        sleep 5
    fi
  done

  echo "-----------------------------------------------------"
  echo "批量创建 ${NUM_PROJECTS} 个项目的过程已完成。"
  if [[ -f failed_project_creations.txt ]]; then
    echo "注意：部分项目创建失败，详情请查看文件 failed_project_creations.txt"
  fi
  if [[ -f failed_billing_links.txt ]]; then
    echo "注意：部分项目的结算账号链接失败，详情请查看文件 failed_billing_links.txt"
  fi
  echo ""
  echo "--- GCP 项目创建脚本执行完毕 ---"
}

# 功能2: 创建 API Key
# 注意: 此功能依赖 'jq' 工具来解析JSON。请确保已安装。
create_api_keys() {
  echo "--- 开始执行 API Key 创建脚本 ---"
  echo ""

  # --- 配置 (来自您提供的脚本) ---
  EXPECTED_KEY_PREFIX="Batch Created Key Restricted" # 可选：更新前缀以反映限制
  TARGET_API_SERVICE="generativelanguage.googleapis.com" # 要限制的目标 API 服务
  CURRENT_DATETIME=$(date +%Y%m%d_%H%M%S)
  OUTPUT_CSV_FILE="created_api_keys_${CURRENT_DATETIME}.csv" # 导出 CSV 文件名
  GCLOUD_LIST_STDERR_LOG="gcloud_list_stderr_${CURRENT_DATETIME}.log" # gcloud list 的错误日志

  # (认证、权限)
  echo "重要提示: 请确保您已经通过 'gcloud auth login' 进行了认证，并且拥有必要的权限来列出项目、创建和更新API密钥。"

  # --- 初始化输出文件 ---
  echo "Project ID,Key Display Name,Key Resource Name,Key UID,Restricted To API,Restriction Status" > "$OUTPUT_CSV_FILE"
  echo "输出 CSV 将保存到: $OUTPUT_CSV_FILE"
  echo "gcloud list 的错误 (如果有) 将保存到: $GCLOUD_LIST_STDERR_LOG"

  # --- 获取项目列表 ---
  echo "正在获取活动项目列表..."
  PROJECT_IDS=$(gcloud projects list --filter="lifecycleState=ACTIVE" --format='value(project_id)' 2> "$GCLOUD_LIST_STDERR_LOG")
  FETCH_EXIT_CODE=$?

  echo "--- DEBUG START ---"
  echo "gcloud projects list exit code: $FETCH_EXIT_CODE"
  echo "Contents of $GCLOUD_LIST_STDERR_LOG (if any):"
  cat "$GCLOUD_LIST_STDERR_LOG"
  echo "Raw content assigned to PROJECT_IDS variable (first 5 lines):"
  echo "$PROJECT_IDS" | head -n 5
  PROJECT_ID_COUNT=$(echo "$PROJECT_IDS" | wc -w)
  echo "Word count (number of projects found in variable): $PROJECT_ID_COUNT"
  echo "--- DEBUG END ---"

  if [ $FETCH_EXIT_CODE -ne 0 ]; then
    echo "获取项目列表时出错 (退出码: $FETCH_EXIT_CODE)。请检查错误日志 '$GCLOUD_LIST_STDERR_LOG' 和您的权限。"
    # return 1 # 如果获取列表失败，可以选择返回主菜单
  fi

  if [ "$PROJECT_ID_COUNT" -eq 0 ]; then
      echo "在脚本内部，没有活动项目被分配给 PROJECT_IDS 变量。"
  else
      echo "发现 $PROJECT_ID_COUNT 个项目ID。即将开始处理循环..."
  fi

  SKIPPED_COUNT=0
  CREATED_COUNT=0
  ERROR_COUNT=0
  RESTRICTION_FAILED_COUNT=0

  echo "尝试进入处理循环..."
  PROJECT_COUNTER=0
  for PROJECT_ID in $PROJECT_IDS
  do
    PROJECT_COUNTER=$((PROJECT_COUNTER + 1))
    echo "--- LOOP ITERATION $PROJECT_COUNTER / $PROJECT_ID_COUNT ---"
    echo "-------------------------------------"
    echo "正在处理项目: $PROJECT_ID"

    echo "  正在检查是否存在前缀为 '$EXPECTED_KEY_PREFIX' 的现有密钥..."
    EXISTING_KEYS_OUTPUT=$(gcloud services api-keys list \
                            --project="$PROJECT_ID" \
                            --filter="displayName~'^$EXPECTED_KEY_PREFIX'" \
                            --format='value(name)' \
                            --limit=1 2>/dev/null)
    LIST_EXIT_CODE=$?

    if [ $LIST_EXIT_CODE -ne 0 ]; then
        LIST_ERROR_CHECK=$(gcloud services api-keys list --project="$PROJECT_ID" --limit=1 2>&1)
        if echo "$LIST_ERROR_CHECK" | grep -q "ApiKeys API is not enabled"; then
          echo "  信息: 项目 $PROJECT_ID 的 ApiKeys API 未启用。正在跳过。"
        elif echo "$LIST_ERROR_CHECK" | grep -q "consumer does not have access"; then
          echo "  错误: 列出项目 $PROJECT_ID 的密钥时权限被拒绝。正在跳过。"
        else
          echo "  错误: 列出项目 $PROJECT_ID 的密钥时出错 (退出码: $LIST_EXIT_CODE)。输出/错误: $LIST_ERROR_CHECK。正在跳过。"
        fi
        ((ERROR_COUNT++))
        continue
    fi

    if [ ! -z "$EXISTING_KEYS_OUTPUT" ]; then
      echo "  发现匹配前缀 '$EXPECTED_KEY_PREFIX' 的现有密钥。正在跳过创建。"
      ((SKIPPED_COUNT++))
      continue
    else
      echo "  未找到具有该前缀的现有受限密钥。继续操作..."

      CURRENT_DATE=$(date +%Y%m%d)
      KEY_DISPLAY_NAME="$EXPECTED_KEY_PREFIX - $CURRENT_DATE"
      echo "  尝试创建 API 密钥 '$KEY_DISPLAY_NAME' (初始无限制)..."

      KEY_OUTPUT=$(gcloud services api-keys create \
        --project="$PROJECT_ID" \
        --display-name="$KEY_DISPLAY_NAME" \
        --format="json")
      CREATE_EXIT_CODE=$?

      if [ $CREATE_EXIT_CODE -ne 0 ]; then
        echo "  创建密钥 (步骤 1) 时出错，项目 $PROJECT_ID。退出码: $CREATE_EXIT_CODE."
        ERROR_MESSAGE=$(echo "$KEY_OUTPUT" | jq -r '.error.message' 2>/dev/null)
        if [ -z "$ERROR_MESSAGE" ] || [ "$ERROR_MESSAGE" == "null" ]; then
            RAW_ERROR_OUTPUT=$(gcloud services api-keys create --project="$PROJECT_ID" --display-name="$KEY_DISPLAY_NAME" 2>&1 >/dev/null)
            ERROR_MESSAGE="原始 gcloud 错误: $RAW_ERROR_OUTPUT"
        fi
        echo "    错误详情: $ERROR_MESSAGE"
        if echo "$ERROR_MESSAGE" | grep -q "caller does not have permission"; then
          echo "    提示: 调用者可能缺少项目 $PROJECT_ID 上的 'apikeys.keys.create' 权限。"
        elif echo "$ERROR_MESSAGE" | grep -q "ApiKeys API is not enabled"; then
          echo "    提示: 可能需要为项目 $PROJECT_ID 启用 API Keys API (apikeys.googleapis.com)。"
        fi
        ((ERROR_COUNT++))
        continue
      else
        KEY_NAME=$(echo "$KEY_OUTPUT" | jq -r '.name')
        KEY_UID=$(echo "$KEY_OUTPUT" | jq -r '.uid')
        echo "    成功创建密钥 (步骤 1)。"
        echo "      密钥显示名称: $KEY_DISPLAY_NAME"
        echo "      密钥资源名称: $KEY_NAME"
        echo "      密钥 UID: $KEY_UID"

        echo "  尝试应用 API 限制 (步骤 2): 仅允许 '$TARGET_API_SERVICE'..."
        UPDATE_OUTPUT=$(gcloud services api-keys update "$KEY_NAME" \
          --project="$PROJECT_ID" \
          --add-api-target="service=$TARGET_API_SERVICE" \
          --format="json" 2>&1)
        UPDATE_EXIT_CODE=$?
        RESTRICTION_STATUS="Failed"

        if [ $UPDATE_EXIT_CODE -ne 0 ]; then
          echo "  为项目 $PROJECT_ID 中的密钥 $KEY_NAME 应用 API 限制 (步骤 2) 时出错。退出码: $UPDATE_EXIT_CODE。"
          echo "    更新命令输出/错误: $UPDATE_OUTPUT"
          if echo "$UPDATE_OUTPUT" | grep -q "Permission denied on service" || echo "$UPDATE_OUTPUT" | grep -q "needs to be enabled"; then
              echo "    提示: 目标 API '$TARGET_API_SERVICE' 可能未在项目 $PROJECT_ID 中启用，或者您缺少 'serviceusage.services.use' 权限。"
          elif echo "$UPDATE_OUTPUT" | grep -q "caller does not have permission"; then
              echo "    提示: 调用者可能缺少对密钥或项目的 'apikeys.keys.update' 权限。"
          fi
          ((RESTRICTION_FAILED_COUNT++))
          ((CREATED_COUNT++)) # 即使限制失败，也算创建成功
        else
          echo "    成功应用 API 限制 '$TARGET_API_SERVICE'。"
          RESTRICTION_STATUS="Success"
          ((CREATED_COUNT++))
        fi
        echo "\"$PROJECT_ID\",\"$KEY_DISPLAY_NAME\",\"$KEY_NAME\",\"$KEY_UID\",\"$TARGET_API_SERVICE\",\"$RESTRICTION_STATUS\"" >> "$OUTPUT_CSV_FILE"
      fi
    fi
  done
  echo "处理循环在 $PROJECT_COUNTER 次迭代后退出。"

  echo "====================================="
  echo "批量受限 API 密钥创建过程已完成。"
  echo "总结:"
  echo "  gcloud list 找到的项目数: $PROJECT_ID_COUNT"
  echo "  循环迭代启动次数: $PROJECT_COUNTER"
  echo "  成功创建的密钥数 (步骤 1): $CREATED_COUNT"
  echo "    (注意: 此计数包括限制步骤可能失败的密钥)"
  echo "  API 限制应用失败数 (步骤 2): $RESTRICTION_FAILED_COUNT"
  echo "  跳过的项目数 (找到现有密钥): $SKIPPED_COUNT"
  echo "  遇到的错误数 (列出密钥、初始创建失败等): $ERROR_COUNT"
  echo "-------------------------------------"
  echo "创建的 API 密钥详细信息已导出到: $OUTPUT_CSV_FILE"
  echo "来自 'gcloud projects list' 的错误 (如果有) 已记录到: $GCLOUD_LIST_STDERR_LOG"
  echo "重要: 请检查 CSV 文件中的 'Restriction Status' 列。"
  echo "重要: 请在 Google Cloud Console 中验证密钥和限制。"
  echo "重要: 出于安全原因，实际的 API 密钥字符串不包含在 CSV 中。"
  echo "如果需要密钥字符串，请使用 'gcloud services api-keys get-key-string projects/PROJECT_NUMBER/locations/global/keys/KEY_ID --project=PROJECT_ID'。"
  echo "请妥善保管所有凭证。"
  echo ""
  echo "--- API Key 创建脚本执行完毕 ---"
}

# 功能3: 启用 API
enable_gcp_apis() {
  echo "--- 开始执行 API 启用脚本 ---"
  echo ""

  # --- 配置 ---
  # !! 重要：请根据你的需求修改或确认要启用的 API 服务名称 !!
  # 选项 1: 只启用 Generative Language API
  APIS_TO_ENABLE="generativelanguage.googleapis.com"
  # 选项 2: 只启用 Vertex AI API (推荐，功能更全)
  #APIS_TO_ENABLE="aiplatform.googleapis.com"
  # 选项 3: 同时启用两者 (如果需要, 用空格分隔)
  # APIS_TO_ENABLE="generativelanguage.googleapis.com aiplatform.googleapis.com" # 示例：启用多个API

  # --- 身份验证和权限检查提示 ---
  echo "=================================================================="
  echo "重要提示：请确保满足以下条件："
  echo "1. 您已通过 'gcloud auth login' 使用具有足够权限的账号登录。"
  echo "2. 该账号在【所有】目标项目上拥有启用API的权限。"
  echo "   (例如 'roles/serviceusage.serviceUsageAdmin', 'roles/editor', 'roles/owner')"
  echo "3. 您已在脚本的 'APIS_TO_ENABLE' 变量中指定了【正确】的 API 服务名称。"
  echo "=================================================================="
  read -p "确认已满足以上条件并准备继续吗？按 Enter 继续，按 Ctrl+C 退出..."

  # --- 获取活动项目列表 ---
  echo "正在获取活动项目列表..."
  PROJECT_IDS=$(gcloud projects list --filter="lifecycleState=ACTIVE" --format='value(project_id)')

  # 检查获取项目列表是否成功以及是否为空
  if [ $? -ne 0 ] || [ -z "$PROJECT_IDS" ]; then
    echo "错误：获取活动项目列表失败，或者没有找到活动项目。"
    echo "API 启用中止。"
    return 1 # 返回主菜单
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
  if [ "$PROJECT_COUNT" -gt 5 ]; then
    echo "..."
  fi
  read -p "确认要为所有 $PROJECT_COUNT 个项目执行此操作吗？(输入 'yes' 确认): " CONFIRM
  # 强制用户输入 'yes' 才继续，增加安全性
  if [[ "$CONFIRM" != "yes" ]]; then
      echo "操作已取消。"
      echo "API 启用中止。"
      return 0 # 用户取消，正常返回主菜单
  fi

  # --- 循环遍历项目并启用 API ---
  SUCCESS_COUNT=0
  FAILURE_COUNT=0
  ALREADY_ENABLED_COUNT=0 # 此计数在 gcloud services enable 中不直接提供，但可以基于输出判断
  CURRENT_PROJECT_NUM=0

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
          # gcloud services enable 通常对于已启用的服务也是返回0，且输出中可能不包含特定"already enabled"字样
          # 所以 ALREADY_ENABLED_COUNT 的精确性有限
          # if echo "$ENABLE_OUTPUT" | grep -q -i "already enabled"; then
          # ((ALREADY_ENABLED_COUNT++))
          # fi
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
  echo ""
  echo "--- API 启用脚本执行完毕 ---"
  # 函数成功结束，隐式返回0
}


# --- 主脚本逻辑 ---

# 清屏 (可选)
clear

while true
do
  # 显示菜单标题
  echo "============================"
  echo " 主 菜 单 "
  echo "============================"
  echo " 1. 创建 GCP 项目"
  echo " 2. 创建 API Key"
  echo " 3. 启用 API" # 更新了名称
  echo " 4. 退出"
  echo "============================"

  # 读取用户输入
  read -p "请输入选项 (1-4): " choice

  # 根据用户输入执行不同操作
  case $choice in
    1)
      echo ""
      create_gcp_projects # 调用创建项目的函数
      echo ""
      read -p "按任意键返回主菜单..."
      clear
      ;;
    2)
      echo ""
      create_api_keys # 调用创建 API Key 的函数
      echo ""
      read -p "按任意键返回主菜单..."
      clear
      ;;
    3)
      echo ""
      enable_gcp_apis # 调用启用 API 的函数
      echo ""
      read -p "按任意键返回主菜单..."
      clear
      ;;
    4)
      echo ""
      echo "感谢使用，再见！"
      exit 0
      ;;
    *)
      echo ""
      echo "无效的输入，请输入有效的数字选项。"
      echo ""
      read -p "按任意键返回主菜单..."
      clear
      ;;
  esac
done
