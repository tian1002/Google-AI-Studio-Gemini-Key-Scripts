#!/bin/bash

# --- 函数定义区域 ---

# 功能1: 创建 GCP 项目
create_gcp_projects() {
  echo "--- 开始执行 GCP 项目创建脚本 ---"
  echo ""

  # --- 变量定义 ---

  # 1. 自动生成项目 ID 的前缀
  FIRST_CHAR=$(head /dev/urandom | tr -dc 'a-z' | head -c 1)
  REST_CHARS=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 9)
  PROJECT_ID_PREFIX="${FIRST_CHAR}${REST_CHARS}"
  echo "本次运行将使用的随机项目 ID 前缀: ${PROJECT_ID_PREFIX}"

  # 2. 尝试自动获取你的数字组织 ID
  echo "正在尝试自动获取组织 ID..."
  ORGANIZATION_ID=$(gcloud organizations list --format="value(ID)" --limit=1 2>/dev/null)
  PARENT_RESOURCE="" # 初始化 PARENT_RESOURCE

  if [[ -z "$ORGANIZATION_ID" ]]; then
    echo "信息：无法自动获取组织 ID。这可能是因为您的账户不属于任何组织，或者权限不足。"
    read -p "您想在没有组织的情况下继续创建项目吗？项目将直接在您的账户下创建。(yes/no): " CONFIRM_NO_ORG
    if [[ "$CONFIRM_NO_ORG" == "yes" ]]; then
      echo "将在没有组织的情况下创建项目。"
      PARENT_RESOURCE="" # 明确设置为空，gcloud 会在用户账户下创建
    else
      echo "项目创建已取消，因为未指定组织且用户选择不继续。"
      return 1 # 返回到主菜单
    fi
  else
    echo "成功获取组织 ID: ${ORGANIZATION_ID}"
    PARENT_RESOURCE="--organization=${ORGANIZATION_ID}"
  fi

  # 3. (可选) 设置你的结算账号 ID
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

  LINK_BILLING=false
  if [[ -n "$BILLING_ACCOUNT_ID" && "$BILLING_ACCOUNT_ID" != "YOUR_BILLING_ACCOUNT_ID" ]]; then
      LINK_BILLING=true
      echo "配置了结算账号 ID: ${BILLING_ACCOUNT_ID}，将在创建后尝试链接。"
  else
      echo "未配置有效的结算账号 ID，将跳过自动链接步骤。"
  fi

  if [[ -z "$PARENT_RESOURCE" ]]; then
    echo "准备创建 ${NUM_PROJECTS} 个项目，前缀为 '${PROJECT_ID_PREFIX}' (无父级组织/文件夹)..."
  else
    echo "准备创建 ${NUM_PROJECTS} 个项目，前缀为 '${PROJECT_ID_PREFIX}'，父资源为 '${PARENT_RESOURCE}'..."
  fi
  echo "-----------------------------------------------------"

  for i in $(seq 1 ${NUM_PROJECTS})
  do
    PROJECT_ID_SUFFIX=$(printf "%03d" ${i})
    FULL_PROJECT_ID="${PROJECT_ID_PREFIX}-${PROJECT_ID_SUFFIX}"
    FULL_PROJECT_ID=${FULL_PROJECT_ID:0:30}

    echo ""
    echo "--> 正在创建项目 #${i} (总共 ${NUM_PROJECTS} 个): ${FULL_PROJECT_ID} ..."

    if [[ -z "$PARENT_RESOURCE" ]]; then
        COMMAND_CREATE="gcloud projects create ${FULL_PROJECT_ID} --name=\"${FULL_PROJECT_ID}-friendly-name\""
    else
        COMMAND_CREATE="gcloud projects create ${FULL_PROJECT_ID} ${PARENT_RESOURCE} --name=\"${FULL_PROJECT_ID}-friendly-name\""
    fi

    echo "    执行命令: $COMMAND_CREATE"
    if eval $COMMAND_CREATE; then
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

# 功能2: 创建/导出 API Key (包含密钥字符串)
# 注意: 此功能依赖 'jq' 工具来解析JSON。请确保已安装。
create_api_keys() {
  echo "--- 开始执行 API Key 创建/导出脚本 ---"
  echo ""

  # --- 配置 ---
  EXPECTED_KEY_PREFIX="Batch Created Key Restricted" # 选项 1 使用的前缀
  TARGET_API_SERVICE="generativelanguage.googleapis.com" # 选项 1 使用的目标 API 服务
  CURRENT_DATETIME=$(date +%Y%m%d_%H%M%S)

  # --- 文件名定义 ---
  OPTION1_CSV_FILE="created_api_keys_with_secrets_${CURRENT_DATETIME}.csv"
  OPTION2_CSV_FILE="all_existing_api_keys_WITH_SECRETS_${CURRENT_DATETIME}.csv"
  GCLOUD_LIST_STDERR_LOG="gcloud_list_stderr_${CURRENT_DATETIME}.log" # gcloud projects list 的错误日志
  GCLOUD_LIST_KEYS_STDERR_LOG="gcloud_list_keys_stderr_${CURRENT_DATETIME}.log" # gcloud api-keys list 的错误日志 (选项2)


  # --- (认证与权限) ---
  echo "重要提示: 请确保您已经通过 'gcloud auth login' 进行了认证，并且拥有必要的权限。"
  echo "  操作 1 (创建新密钥) 需要权限: roles/apikeys.creator, roles/apikeys.updater, apikeys.keys.getKeyString (或更高)"
  echo "  操作 2 (导出所有密钥) 需要权限: roles/apikeys.viewer, apikeys.keys.list, apikeys.keys.getKeyString (对所有目标项目)"
  echo ""

  # --- 获取用户选择 ---
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "!!!                          重要安全警告                                  !!!"
  echo "!!!   此功能将导出【包含敏感 API 密钥字符串】的 CSV 文件。                 !!!"
  echo "!!!   这些密钥是可以直接使用的凭证，泄露将导致严重安全风险！           !!!"
  echo "!!!   请仅在完全了解并接受风险的情况下继续。                             !!!"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "--------------------------------------------------"
  echo "请选择要执行的操作："
  echo "  1. 创建缺失的受限密钥 (前缀: '$EXPECTED_KEY_PREFIX', 限制: '$TARGET_API_SERVICE')，"
  echo "     并导出本次【新创建】密钥的详细信息 (包含 API 密钥字符串)。"
  echo "  2. 扫描所有活动项目中的【所有】已存在 API 密钥，"
  echo "     并导出它们的详细信息 (【包含 API 密钥字符串 - 极高风险!】)。"
  echo "--------------------------------------------------"
  read -p "请输入你的选择 (1 或 2): " USER_CHOICE
  echo

  local ACTION_MODE="" # 声明为局部变量

  case "$USER_CHOICE" in
      1)
          echo "选择操作 1: 创建并导出【新创建】的受限密钥 (包含密钥字符串)..."
          echo "!!! 输出文件: $OPTION1_CSV_FILE (包含敏感密钥)"
          echo "Project ID,Key Display Name,Key Resource Name,Key UID,Restricted To API,Restriction Status,API Key String" > "$OPTION1_CSV_FILE"
          ACTION_MODE="CREATE_AND_EXPORT_NEW"
          ;;
      2)
          echo "选择操作 2: 导出【所有已存在】API 密钥的详细信息 (包含密钥字符串)..."
          echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
          echo "!!!          警告：此操作将导出所有找到的密钥字符串，风险极高！          !!!"
          echo "!!!          输出文件: $OPTION2_CSV_FILE                               !!!"
          echo "!!!          请像对待最高机密文件一样处理此文件！                      !!!"
          echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
          echo "Project ID,Key Display Name,Key Resource Name,Key UID,API Key String" > "$OPTION2_CSV_FILE"
          ACTION_MODE="EXPORT_ALL_EXISTING_WITH_SECRETS"
          ;;
      *)
          echo "无效的选择 '$USER_CHOICE'. 请输入 1 或 2."
          echo "API Key 操作中止。"
          return 1 # 无效选择则从函数返回
          ;;
  esac

  echo "gcloud projects list 命令的错误 (如果有) 将会保存在: $GCLOUD_LIST_STDERR_LOG"
  # read -p "按 Enter 继续执行所选操作（包含高风险操作），按 Ctrl+C 中止..." # 可选的确认步骤

  # --- 获取项目列表 (两种模式都需要) ---
  echo "正在获取活动项目列表..."
  PROJECT_IDS=$(gcloud projects list --filter="lifecycleState=ACTIVE" --format='value(project_id)' 2> "$GCLOUD_LIST_STDERR_LOG")
  FETCH_EXIT_CODE=$?

  echo "--- 调试信息开始 ---"
  echo "gcloud projects list 退出状态码: $FETCH_EXIT_CODE"
  echo "$GCLOUD_LIST_STDERR_LOG 文件内容 (如果有):"
  cat "$GCLOUD_LIST_STDERR_LOG"
  echo "赋值给 PROJECT_IDS 变量的原始内容 (前5行):"
  echo "$PROJECT_IDS" | head -n 5
  PROJECT_ID_COUNT=$(echo "$PROJECT_IDS" | wc -w)
  echo "PROJECT_IDS 变量中的项目数量 (词数统计): $PROJECT_ID_COUNT"
  echo "--- 调试信息结束 ---"

  if [ $FETCH_EXIT_CODE -ne 0 ]; then
    echo "获取项目列表时出错 (退出状态码: $FETCH_EXIT_CODE). 请检查 '$GCLOUD_LIST_STDERR_LOG' 文件以及您的权限。"
    echo "API Key 操作中止。"
    return 1
  fi
  if [ "$PROJECT_ID_COUNT" -eq 0 ]; then
     echo "在 PROJECT_IDS 变量中没有找到活动项目。脚本结束。"
     return 0
  else
      echo "找到了 $PROJECT_ID_COUNT 个项目ID。开始处理..."
  fi

  # --- 初始化计数器 ---
  local SKIPPED_COUNT=0 CREATED_COUNT=0 ERROR_COUNT_OPT1=0 RESTRICTION_FAILED_COUNT=0 GET_KEY_STRING_FAILED_COUNT_OPT1=0
  local EXPORTED_EXISTING_COUNT=0 ERROR_COUNT_OPT2=0 GET_KEY_STRING_FAILED_COUNT_OPT2=0
  local PROJECT_COUNTER=0

  echo "尝试进入项目处理循环..."
  for PROJECT_ID in $PROJECT_IDS
  do
    PROJECT_COUNTER=$((PROJECT_COUNTER + 1))
    echo "--- 循环迭代 $PROJECT_COUNTER / $PROJECT_ID_COUNT ---"
    echo "-------------------------------------"
    echo "正在处理项目: $PROJECT_ID"

    if [ "$ACTION_MODE" == "CREATE_AND_EXPORT_NEW" ]; then
        echo "  操作 1: 检查项目 '$PROJECT_ID' 中是否存在前缀为 '$EXPECTED_KEY_PREFIX' 的密钥..."
        EXISTING_KEYS_OUTPUT=$(gcloud services api-keys list --project="$PROJECT_ID" --filter="displayName~'^$EXPECTED_KEY_PREFIX'" --format='value(name)' --limit=1 2>/dev/null)
        LIST_EXIT_CODE=$?
        if [ $LIST_EXIT_CODE -ne 0 ]; then
           # 尝试获取更详细的错误
           LIST_ERROR_DETAILS=$(gcloud services api-keys list --project="$PROJECT_ID" --filter="displayName~'^$EXPECTED_KEY_PREFIX'" --limit=1 2>&1 >/dev/null)
           echo "  错误：列出项目 '$PROJECT_ID' 中的密钥失败。错误详情: $LIST_ERROR_DETAILS 跳过此项目。"
           ((ERROR_COUNT_OPT1++))
           continue
        fi

        if [ ! -z "$EXISTING_KEYS_OUTPUT" ]; then
          echo "  信息：找到已存在符合前缀的密钥。跳过创建。"
          ((SKIPPED_COUNT++))
          continue
        else
          echo "  信息：未找到符合前缀的密钥。开始创建..."
          CURRENT_DATE_OPT1=$(date +%Y%m%d) # 为选项1使用独立的日期变量，避免和外部的混淆
          KEY_DISPLAY_NAME_OPT1="$EXPECTED_KEY_PREFIX - $CURRENT_DATE_OPT1"
          echo "  步骤 1: 尝试创建 API 密钥 '$KEY_DISPLAY_NAME_OPT1'..."
          KEY_OUTPUT_OPT1=$(gcloud services api-keys create --project="$PROJECT_ID" --display-name="$KEY_DISPLAY_NAME_OPT1" --format="json")
          CREATE_EXIT_CODE_OPT1=$?
          if [ $CREATE_EXIT_CODE_OPT1 -ne 0 ]; then
              echo "  错误：创建密钥失败 (项目: $PROJECT_ID)。错误输出: $KEY_OUTPUT_OPT1 跳过。"
              ((ERROR_COUNT_OPT1++))
              continue
          else
              KEY_NAME_OPT1=$(echo "$KEY_OUTPUT_OPT1" | jq -r '.name')
              KEY_UID_OPT1=$(echo "$KEY_OUTPUT_OPT1" | jq -r '.uid')
              echo "    成功：密钥已创建。资源名: $KEY_NAME_OPT1"

              echo "  步骤 2: 尝试应用 API 限制..."
              UPDATE_OUTPUT_OPT1=$(gcloud services api-keys update "$KEY_NAME_OPT1" --project="$PROJECT_ID" --add-api-target="service=$TARGET_API_SERVICE" --format="json" 2>&1)
              UPDATE_EXIT_CODE_OPT1=$?
              RESTRICTION_STATUS_OPT1="失败"
              if [ $UPDATE_EXIT_CODE_OPT1 -ne 0 ]; then
                  echo "  错误：应用 API 限制失败 (密钥: $KEY_NAME_OPT1)。错误输出: $UPDATE_OUTPUT_OPT1"
                  ((RESTRICTION_FAILED_COUNT++))
              else
                  RESTRICTION_STATUS_OPT1="成功"
                  echo "    成功：已应用 API 限制 '$TARGET_API_SERVICE'。"
              fi
              ((CREATED_COUNT++))

              API_KEY_STRING_OPT1="获取密钥字符串失败"
              echo "  步骤 3: 尝试获取 API 密钥字符串..."
              FETCHED_KEY_STRING_OPT1=$(gcloud services api-keys get-key-string "$KEY_NAME_OPT1" --project="$PROJECT_ID" --format='value(keyString)' 2>&1)
              GET_STRING_EXIT_CODE_OPT1=$?
              if [ $GET_STRING_EXIT_CODE_OPT1 -ne 0 ]; then
                  echo "  错误：获取 API 密钥字符串失败 (密钥: $KEY_NAME_OPT1)。"
                  echo "    错误详情: $FETCHED_KEY_STRING_OPT1"
                  ((GET_KEY_STRING_FAILED_COUNT_OPT1++))
              else
                  API_KEY_STRING_OPT1="$FETCHED_KEY_STRING_OPT1"
                  echo "    成功：已获取 API 密钥字符串 (请极其小心处理！)。"
              fi
              echo "\"$PROJECT_ID\",\"$KEY_DISPLAY_NAME_OPT1\",\"$KEY_NAME_OPT1\",\"$KEY_UID_OPT1\",\"$TARGET_API_SERVICE\",\"$RESTRICTION_STATUS_OPT1\",\"$API_KEY_STRING_OPT1\"" >> "$OPTION1_CSV_FILE"
          fi
        fi

    elif [ "$ACTION_MODE" == "EXPORT_ALL_EXISTING_WITH_SECRETS" ]; then
        echo "  操作 2: 列出项目 '$PROJECT_ID' 中的【所有】已存在密钥..."
        # 将 gcloud api-keys list 的 stderr 重定向到特定日志文件
        ALL_KEYS_JSON=$(gcloud services api-keys list --project="$PROJECT_ID" --format="json" 2> "$GCLOUD_LIST_KEYS_STDERR_LOG")
        LIST_KEYS_EXIT_CODE=$?

        if [ $LIST_KEYS_EXIT_CODE -ne 0 ]; then
            LIST_KEYS_STDERR_CONTENT=$(cat "$GCLOUD_LIST_KEYS_STDERR_LOG")
            echo "  错误：列出项目 '$PROJECT_ID' 中的密钥失败 (退出状态码: $LIST_KEYS_EXIT_CODE)。跳过此项目。"
            if echo "$LIST_KEYS_STDERR_CONTENT" | grep -q "ApiKeys API is not enabled"; then
                echo "    提示：项目 '$PROJECT_ID' 的 ApiKeys API 未启用。"
            elif echo "$LIST_KEYS_STDERR_CONTENT" | grep -q "consumer does not have access"; then
                echo "    提示：无权列出项目 '$PROJECT_ID' 中的密钥。"
            else
                echo "    错误详情: $LIST_KEYS_STDERR_CONTENT"
            fi
            ((ERROR_COUNT_OPT2++))
            # rm -f "$GCLOUD_LIST_KEYS_STDERR_LOG" # 可以在循环外清理，或每次覆盖
            continue
        fi
        # 如果成功，可以选择删除或清空日志
        > "$GCLOUD_LIST_KEYS_STDERR_LOG" # 清空日志文件

        KEY_FOUND_IN_PROJECT=0
        if echo "$ALL_KEYS_JSON" | jq -e 'type == "array"' > /dev/null; then
            echo "$ALL_KEYS_JSON" | jq -c '.[]?' | while IFS= read -r key_json; do
                if [ -z "$key_json" ] || [ "$key_json" == "null" ]; then
                    continue
                fi
                KEY_FOUND_IN_PROJECT=1

                KEY_NAME_OPT2=$(echo "$key_json" | jq -r '.name')
                if [ -z "$KEY_NAME_OPT2" ] || [ "$KEY_NAME_OPT2" == "null" ]; then
                    echo "      警告：在密钥 JSON 对象中未能提取有效的 'name' 字段，跳过此条目。"
                    echo "      有问题的条目 JSON: $key_json"
                    continue
                fi

                KEY_DISPLAY_NAME_OPT2=$(echo "$key_json" | jq -r '.displayName // "(无显示名称)"')
                KEY_UID_OPT2=$(echo "$key_json" | jq -r '.uid // "(未知UID)"')
                echo "    找到已存在密钥: 显示名称='$KEY_DISPLAY_NAME_OPT2', 资源名='$KEY_NAME_OPT2'"

                API_KEY_STRING_OPT2="获取密钥字符串失败"
                echo "      尝试获取 API 密钥字符串 (高风险操作！)..."
                FETCHED_KEY_STRING_OPT2=$(gcloud services api-keys get-key-string "$KEY_NAME_OPT2" --project="$PROJECT_ID" --format='value(keyString)' 2>&1)
                GET_STRING_EXIT_CODE_OPT2=$?

                if [ $GET_STRING_EXIT_CODE_OPT2 -ne 0 ]; then
                    echo "      错误：获取密钥 '$KEY_NAME_OPT2' 的 API 密钥字符串失败 (退出状态码: $GET_STRING_EXIT_CODE_OPT2)。"
                    echo "      错误详情: $FETCHED_KEY_STRING_OPT2"
                    if echo "$FETCHED_KEY_STRING_OPT2" | grep -q "caller does not have permission"; then
                        echo "        提示：可能缺少 'apikeys.keys.getKeyString' 权限。"
                    fi
                    ((GET_KEY_STRING_FAILED_COUNT_OPT2++))
                else
                    API_KEY_STRING_OPT2="$FETCHED_KEY_STRING_OPT2"
                    echo "      成功：已获取密钥 '$KEY_NAME_OPT2' 的 API 密钥字符串 (请极其小心处理！)。"
                fi

                echo "\"$PROJECT_ID\",\"$KEY_DISPLAY_NAME_OPT2\",\"$KEY_NAME_OPT2\",\"$KEY_UID_OPT2\",\"$API_KEY_STRING_OPT2\"" >> "$OPTION2_CSV_FILE"
                ((EXPORTED_EXISTING_COUNT++))
            done
        else
            echo "  信息：项目 '$PROJECT_ID' 的 JSON 响应不是预期的密钥数组。"
            echo "    项目 '$PROJECT_ID' 的原始 JSON 响应为: $ALL_KEYS_JSON"
        fi

        if [ $KEY_FOUND_IN_PROJECT -eq 0 ]; then
            echo "  信息：项目 '$PROJECT_ID' 中未找到或未处理 API 密钥。"
        else
            echo "  信息：已完成处理项目 '$PROJECT_ID' 中的已存在密钥。"
        fi
    fi
  done
  echo "已退出项目处理循环，共迭代 $PROJECT_COUNTER 次。"

  # --- 总结 ---
  echo "====================================="
  echo "批量 API 密钥处理操作已完成。"

  if [ "$ACTION_MODE" == "CREATE_AND_EXPORT_NEW" ]; then
      echo "--- 操作 1 总结 (创建并导出新密钥) ---"
      echo "!!! 警告: 包含敏感 API 密钥字符串的文件已导出至 $OPTION1_CSV_FILE !!!"
      echo "-----------------------------------------------------------------------"
      echo "  gcloud list 找到的项目总数: $PROJECT_ID_COUNT"
      echo "  实际开始处理的项目（循环迭代次数）: $PROJECT_COUNTER"
      echo "  成功创建的新密钥数量 (步骤 1): $CREATED_COUNT"
      echo "  API 限制应用失败次数 (步骤 2): $RESTRICTION_FAILED_COUNT"
      echo "  获取新密钥的 API 密钥字符串失败次数 (步骤 3): $GET_KEY_STRING_FAILED_COUNT_OPT1"
      echo "  跳过的项目数 (因密钥已存在): $SKIPPED_COUNT"
      echo "  遇到的错误数 (列出密钥、创建密钥失败等): $ERROR_COUNT_OPT1"
      echo "-------------------------------------"
      echo "新创建密钥的详细信息已导出至: $OPTION1_CSV_FILE"

  elif [ "$ACTION_MODE" == "EXPORT_ALL_EXISTING_WITH_SECRETS" ]; then
      echo "--- 操作 2 总结 (导出所有已存在密钥及其字符串) ---"
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! 高风险输出 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      echo "!!! 警告: 包含【所有】列出密钥的敏感 API 密钥字符串的文件已导出至:     !!!"
      echo "!!!          $OPTION2_CSV_FILE                                              !!!"
      echo "!!!          请将此文件视为【最高机密】！使用完毕后立即安全删除！          !!!"
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      echo "-------------------------------------------------------------------------------"
      echo "  gcloud list 找到的项目总数: $PROJECT_ID_COUNT"
      echo "  实际开始处理的项目（循环迭代次数）: $PROJECT_COUNTER"
      echo "  找到并处理的已存在密钥总数: $EXPORTED_EXISTING_COUNT"
      echo "  获取已存在密钥的 API 密钥字符串失败的密钥数量: $GET_KEY_STRING_FAILED_COUNT_OPT2"
      echo "  列出密钥时遇到错误的项目数 (已跳过): $ERROR_COUNT_OPT2"
      echo "-------------------------------------"
      echo "【所有】找到的已存在密钥的详细信息 (包含密钥字符串) 已导出至: $OPTION2_CSV_FILE"
  fi

  echo "gcloud projects list 命令的错误 (如果有) 已记录到: $GCLOUD_LIST_STDERR_LOG"
  if [ -s "$GCLOUD_LIST_KEYS_STDERR_LOG" ]; then # 检查 gcloud_list_keys_stderr.log 是否非空
    echo "gcloud api-keys list 命令的错误 (如果有) 已额外记录到: $GCLOUD_LIST_KEYS_STDERR_LOG"
  else
    rm -f "$GCLOUD_LIST_KEYS_STDERR_LOG" # 如果为空则删除
  fi
  echo "重要提示：请在 Google Cloud Console 中验证结果。"
  echo "重要提示：请极其小心地保护【所有包含 API 密钥字符串的输出文件】！"
  echo ""
  echo "--- API Key 创建/导出脚本执行完毕 ---"
  return 0
}

# 功能3: 启用 API
enable_gcp_apis() {
  echo "--- 开始执行 API 启用脚本 ---"
  echo ""

  # --- 配置 ---
  APIS_TO_ENABLE="generativelanguage.googleapis.com"
  # APIS_TO_ENABLE="aiplatform.googleapis.com"
  # APIS_TO_ENABLE="generativelanguage.googleapis.com aiplatform.googleapis.com"

  echo "=================================================================="
  echo "重要提示：请确保满足以下条件："
  echo "1. 您已通过 'gcloud auth login' 使用具有足够权限的账号登录。"
  echo "2. 该账号在【所有】目标项目上拥有启用API的权限。"
  echo "   (例如 'roles/serviceusage.serviceUsageAdmin', 'roles/editor', 'roles/owner')"
  echo "3. 您已在脚本的 'APIS_TO_ENABLE' 变量中指定了【正确】的 API 服务名称。"
  echo "=================================================================="
  read -p "确认已满足以上条件并准备继续吗？按 Enter 继续，按 Ctrl+C 退出..."

  echo "正在获取活动项目列表..."
  PROJECT_IDS=$(gcloud projects list --filter="lifecycleState=ACTIVE" --format='value(project_id)')

  if [ $? -ne 0 ] || [ -z "$PROJECT_IDS" ]; then
    echo "错误：获取活动项目列表失败，或者没有找到活动项目。"
    echo "API 启用中止。"
    return 1
  fi

  PROJECT_COUNT=$(echo "$PROJECT_IDS" | wc -w)
  echo "成功找到 $PROJECT_COUNT 个活动项目。"

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
  if [[ "$CONFIRM" != "yes" ]]; then
      echo "操作已取消。"
      echo "API 启用中止。"
      return 0
  fi

  local SUCCESS_COUNT=0 FAILURE_COUNT=0 CURRENT_PROJECT_NUM=0

  echo "开始批量启用 API..."
  for PROJECT_ID in $PROJECT_IDS; do
      CURRENT_PROJECT_NUM=$((CURRENT_PROJECT_NUM + 1))
      echo "-------------------------------------"
      echo "($CURRENT_PROJECT_NUM/$PROJECT_COUNT) 正在处理项目: $PROJECT_ID"

      ENABLE_OUTPUT=$(gcloud services enable $APIS_TO_ENABLE --project="$PROJECT_ID" 2>&1)
      EXIT_CODE=$?

      if [ $EXIT_CODE -eq 0 ]; then
          echo "  成功：在项目 $PROJECT_ID 中已启用或成功启用了 API: $APIS_TO_ENABLE"
          ((SUCCESS_COUNT++))
      else
          echo "  错误：在项目 $PROJECT_ID 中启用 API 失败 (退出码: $EXIT_CODE)。"
          echo "    错误详情: $ENABLE_OUTPUT"
          if echo "$ENABLE_OUTPUT" | grep -q -i "permission denied" || echo "$ENABLE_OUTPUT" | grep -q -i "caller does not have permission"; then
              echo "    提示：请检查您在此项目上的 'serviceusage.services.enable' 权限。"
          elif echo "$ENABLE_OUTPUT" | grep -q -i "billing account" || echo "$ENABLE_OUTPUT" | grep -q -i "activate billing"; then
              echo "    提示：此 API 可能需要有效的结算帐号与项目关联并启用结算。"
          elif echo "$ENABLE_OUTPUT" | grep -q -i "must be enabled"; then
              DEPENDENCY=$(echo "$ENABLE_OUTPUT" | grep -o -E '[a-zA-Z0-9.-]+\.googleapis\.com must be enabled')
              echo "    提示：可能需要先启用依赖的 API: $DEPENDENCY"
          fi
          ((FAILURE_COUNT++))
      fi
  done

  echo "====================================="
  echo "批量 API 启用过程完成。"
  echo "处理的项目总数: $PROJECT_COUNT"
  echo "成功启用 (或之前已启用) 的项目数: $SUCCESS_COUNT"
  echo "启用失败的项目数: $FAILURE_COUNT"
  echo "====================================="
  if [ $FAILURE_COUNT -gt 0 ]; then
      echo "重要提示：有 $FAILURE_COUNT 个项目未能成功启用 API，请检查上面日志中的错误详情和对应的项目权限/设置。"
  fi
  echo "重要提示：API 服务启用后，如果 API 本身有费用，请确保项目也已经正确关联结算账号并启用了结算。"
  echo ""
  echo "--- API 启用脚本执行完毕 ---"
  return 0
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
  echo " 2. 创建/导出 API Key (含密钥字符串)" # 更新了名称
  echo " 3. 启用 API"
  echo " 4. 退出"
  echo "============================"

  # 读取用户输入
  read -p "请输入选项 (1-4): " choice

  # 根据用户输入执行不同操作
  case $choice in
    1)
      echo ""
      create_gcp_projects
      echo ""
      read -p "按任意键返回主菜单..."
      clear
      ;;
    2)
      echo ""
      create_api_keys # 调用新的 create_api_keys 函数
      echo ""
      read -p "按任意键返回主菜单..."
      clear
      ;;
    3)
      echo ""
      enable_gcp_apis
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
