#!/bin/bash

# --- 配置 ---
EXPECTED_KEY_PREFIX="Batch Created Key Restricted" # 选项 1 使用的前缀，用于新创建的密钥
TARGET_API_SERVICE="generativelanguage.googleapis.com" # 选项 1 使用的目标 API 服务
CURRENT_DATETIME=$(date +%Y%m%d_%H%M%S) # 当前日期和时间，用于文件名

# --- 文件名定义 ---
# !! 文件名现在都明确指出包含敏感密钥 !!
OPTION1_CSV_FILE="created_api_keys_with_secrets_${CURRENT_DATETIME}.csv" # 选项 1 的输出文件名
OPTION2_CSV_FILE="all_existing_api_keys_WITH_SECRETS_${CURRENT_DATETIME}.csv" # 选项 2 的输出文件名 (包含所有密钥)
GCLOUD_LIST_STDERR_LOG="gcloud_list_stderr_${CURRENT_DATETIME}.log" # gcloud projects list 命令的错误日志文件

# --- (认证与权限) ---
# 确保您已经通过 `gcloud auth login` 进行了认证，并且拥有必要的权限。
# 选项 1 需要权限: roles/apikeys.creator, roles/apikeys.updater, apikeys.keys.getKeyString (或更高如 roles/apikeys.admin)
# 选项 2 需要权限: roles/apikeys.viewer, apikeys.keys.list, apikeys.keys.getKeyString (注意：需要能在所有项目上列出并获取所有密钥字符串的权限！)

# --- 获取用户选择 ---
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!!!                          重要安全警告                                  !!!"
echo "!!!   脚本将导出【包含敏感 API 密钥字符串】的 CSV 文件。                   !!!"
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
echo # 输出一个空行，美化格式

# --- 根据用户选择设置变量和执行操作 ---
case "$USER_CHOICE" in
    1)
        echo "选择操作 1: 创建并导出【新创建】的受限密钥 (包含密钥字符串)..."
        echo "!!! 输出文件: $OPTION1_CSV_FILE (包含敏感密钥)"
        # 初始化选项 1 的 CSV 文件头
        echo "Project ID,Key Display Name,Key Resource Name,Key UID,Restricted To API,Restriction Status,API Key String" > "$OPTION1_CSV_FILE"
        ACTION_MODE="CREATE_AND_EXPORT_NEW" # 设置操作模式
        ;;
    2)
        echo "选择操作 2: 导出【所有已存在】API 密钥的详细信息 (包含密钥字符串)..."
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "!!!          警告：此操作将导出所有找到的密钥字符串，风险极高！          !!!"
        echo "!!!          输出文件: $OPTION2_CSV_FILE                               !!!"
        echo "!!!          请像对待最高机密文件一样处理此文件！                      !!!"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        # 初始化选项 2 的 CSV 文件头 (添加 API Key String 列)
        echo "Project ID,Key Display Name,Key Resource Name,Key UID,API Key String" > "$OPTION2_CSV_FILE"
        ACTION_MODE="EXPORT_ALL_EXISTING_WITH_SECRETS" # 设置操作模式
        ;;
    *)
        echo "无效的选择 '$USER_CHOICE'. 请输入 1 或 2."
        exit 1 # 无效选择则退出脚本
        ;;
esac

echo "gcloud projects list 命令的错误 (如果有) 将会保存在: $GCLOUD_LIST_STDERR_LOG"
# 可选：在开始高风险操作前添加一个等待用户确认的步骤
# read -p "按 Enter 继续执行所选操作（包含高风险操作），按 Ctrl+C 中止..."

# --- 获取项目列表 (两种模式都需要) ---
echo "正在获取活动项目列表..."
PROJECT_IDS=$(gcloud projects list --filter="lifecycleState=ACTIVE" --format='value(project_id)' 2> "$GCLOUD_LIST_STDERR_LOG")
FETCH_EXIT_CODE=$? # 获取 gcloud list 命令的退出状态码

# --- 调试信息 ---
echo "--- 调试信息开始 ---"
echo "gcloud projects list 退出状态码: $FETCH_EXIT_CODE"
echo "$GCLOUD_LIST_STDERR_LOG 文件内容 (如果有):"
cat "$GCLOUD_LIST_STDERR_LOG" # 显示 gcloud list 命令可能输出到 stderr 的内容
echo "赋值给 PROJECT_IDS 变量的原始内容 (前5行):"
echo "$PROJECT_IDS" | head -n 5 # 只显示前5行，避免输出过长
PROJECT_ID_COUNT=$(echo "$PROJECT_IDS" | wc -w) # 计算获取到的项目ID数量
echo "PROJECT_IDS 变量中的项目数量 (词数统计): $PROJECT_ID_COUNT"
echo "--- 调试信息结束 ---"

if [ $FETCH_EXIT_CODE -ne 0 ]; then
  echo "获取项目列表时出错 (退出状态码: $FETCH_EXIT_CODE). 请检查 '$GCLOUD_LIST_STDERR_LOG' 文件以及您的权限。"
  exit 1 # 如果无法列出项目，则退出脚本
fi
if [ "$PROJECT_ID_COUNT" -eq 0 ]; then
   echo "在 PROJECT_IDS 变量中没有找到活动项目。脚本结束。"
   exit 0 # 没有项目可处理，正常退出
else
    echo "找到了 $PROJECT_ID_COUNT 个项目ID。开始处理..."
fi

# --- 初始化计数器 ---
# 选项 1 计数器
SKIPPED_COUNT=0                   # 跳过的项目数 (因密钥已存在)
CREATED_COUNT=0                   # 成功创建的密钥数 (步骤1成功)
ERROR_COUNT_OPT1=0                # 选项1中遇到的错误数 (如列出或创建密钥失败)
RESTRICTION_FAILED_COUNT=0        # API限制应用失败的次数
GET_KEY_STRING_FAILED_COUNT_OPT1=0 # 选项1中获取密钥字符串失败的次数
# 选项 2 计数器
EXPORTED_EXISTING_COUNT=0         # 选项2中导出的已存在密钥总数
ERROR_COUNT_OPT2=0                # 选项2中遇到的错误数 (如列出密钥失败)
GET_KEY_STRING_FAILED_COUNT_OPT2=0 # 选项2中获取密钥字符串失败的次数

# --- 循环处理每个项目 ---
echo "尝试进入项目处理循环..."
PROJECT_COUNTER=0 # 当前处理的项目计数器
for PROJECT_ID in $PROJECT_IDS
do
  PROJECT_COUNTER=$((PROJECT_COUNTER + 1)) # 增加项目计数
  echo "--- 循环迭代 $PROJECT_COUNTER / $PROJECT_ID_COUNT ---"
  echo "-------------------------------------"
  echo "正在处理项目: $PROJECT_ID"

  if [ "$ACTION_MODE" == "CREATE_AND_EXPORT_NEW" ]; then
      # --- 选项 1 逻辑: 创建并导出【新创建】的受限密钥 ---
      echo "  操作 1: 检查项目 '$PROJECT_ID' 中是否存在前缀为 '$EXPECTED_KEY_PREFIX' 的密钥..."
      EXISTING_KEYS_OUTPUT=$(gcloud services api-keys list --project="$PROJECT_ID" --filter="displayName~'^$EXPECTED_KEY_PREFIX'" --format='value(name)' --limit=1 2>/dev/null)
      LIST_EXIT_CODE=$?
      if [ $LIST_EXIT_CODE -ne 0 ]; then
         # 此处可以添加更详细的 gcloud services api-keys list 错误检查逻辑
         echo "  错误：列出项目 '$PROJECT_ID' 中的密钥失败。跳过此项目。"
         ((ERROR_COUNT_OPT1++))
         continue # 处理下一个项目
      fi

      if [ ! -z "$EXISTING_KEYS_OUTPUT" ]; then
        echo "  信息：找到已存在符合前缀的密钥。跳过创建。"
        ((SKIPPED_COUNT++))
        continue # 处理下一个项目
      else
        echo "  信息：未找到符合前缀的密钥。开始创建..."
        CURRENT_DATE=$(date +%Y%m%d) # 确保 CURRENT_DATE 已定义
        KEY_DISPLAY_NAME="$EXPECTED_KEY_PREFIX - $CURRENT_DATE"
        echo "  步骤 1: 尝试创建 API 密钥 '$KEY_DISPLAY_NAME'..."
        KEY_OUTPUT=$(gcloud services api-keys create --project="$PROJECT_ID" --display-name="$KEY_DISPLAY_NAME" --format="json")
        CREATE_EXIT_CODE=$?
        if [ $CREATE_EXIT_CODE -ne 0 ]; then
            echo "  错误：创建密钥失败 (项目: $PROJECT_ID)。跳过。"
            # 此处可以解析 $KEY_OUTPUT 中的错误信息
            ((ERROR_COUNT_OPT1++))
            continue # 处理下一个项目
        else
            KEY_NAME=$(echo "$KEY_OUTPUT" | jq -r '.name')
            KEY_UID=$(echo "$KEY_OUTPUT" | jq -r '.uid')
            echo "    成功：密钥已创建。资源名: $KEY_NAME"

            echo "  步骤 2: 尝试应用 API 限制..."
            UPDATE_OUTPUT=$(gcloud services api-keys update "$KEY_NAME" --project="$PROJECT_ID" --add-api-target="service=$TARGET_API_SERVICE" --format="json" 2>&1)
            UPDATE_EXIT_CODE=$?
            RESTRICTION_STATUS="失败" # 默认为失败
            if [ $UPDATE_EXIT_CODE -ne 0 ]; then
                echo "  错误：应用 API 限制失败 (密钥: $KEY_NAME)。"
                # 此处可以解析 $UPDATE_OUTPUT 中的错误信息
                ((RESTRICTION_FAILED_COUNT++))
            else
                RESTRICTION_STATUS="成功"
                echo "    成功：已应用 API 限制 '$TARGET_API_SERVICE'。"
            fi
            ((CREATED_COUNT++)) # 无论限制是否成功，密钥本身创建成功就算一次

            API_KEY_STRING_OPT1="获取密钥字符串失败" # 默认错误信息
            echo "  步骤 3: 尝试获取 API 密钥字符串..."
            FETCHED_KEY_STRING_OPT1=$(gcloud services api-keys get-key-string "$KEY_NAME" --project="$PROJECT_ID" --format='value(keyString)' 2>&1)
            GET_STRING_EXIT_CODE_OPT1=$?
            if [ $GET_STRING_EXIT_CODE_OPT1 -ne 0 ]; then
                echo "  错误：获取 API 密钥字符串失败 (密钥: $KEY_NAME)。"
                echo "    错误详情: $FETCHED_KEY_STRING_OPT1"
                ((GET_KEY_STRING_FAILED_COUNT_OPT1++))
            else
                API_KEY_STRING_OPT1="$FETCHED_KEY_STRING_OPT1"
                echo "    成功：已获取 API 密钥字符串 (请极其小心处理！)。"
            fi
            # 将新创建密钥的详细信息写入 CSV 文件
            echo "\"$PROJECT_ID\",\"$KEY_DISPLAY_NAME\",\"$KEY_NAME\",\"$KEY_UID\",\"$TARGET_API_SERVICE\",\"$RESTRICTION_STATUS\",\"$API_KEY_STRING_OPT1\"" >> "$OPTION1_CSV_FILE"
        fi
      fi

  elif [ "$ACTION_MODE" == "EXPORT_ALL_EXISTING_WITH_SECRETS" ]; then
      # --- 选项 2 逻辑: 导出【所有】已存在 API 密钥的详细信息 (包含密钥字符串) ---
      echo "  操作 2: 列出项目 '$PROJECT_ID' 中的【所有】已存在密钥..."
      ALL_KEYS_JSON=$(gcloud services api-keys list --project="$PROJECT_ID" --format="json" 2> gcloud_list_keys_stderr.log)
      LIST_EXIT_CODE=$?

      if [ $LIST_EXIT_CODE -ne 0 ]; then
          LIST_KEYS_STDERR=$(cat gcloud_list_keys_stderr.log)
          echo "  错误：列出项目 '$PROJECT_ID' 中的密钥失败 (退出状态码: $LIST_EXIT_CODE)。跳过此项目。"
          if echo "$LIST_KEYS_STDERR" | grep -q "ApiKeys API is not enabled"; then # 判断是否因为API未启用
              echo "    提示：项目 '$PROJECT_ID' 的 ApiKeys API 未启用。"
          elif echo "$LIST_KEYS_STDERR" | grep -q "consumer does not have access"; then # 判断是否因为权限不足
              echo "    提示：无权列出项目 '$PROJECT_ID' 中的密钥。"
          else
              echo "    错误详情: $LIST_KEYS_STDERR"
          fi
          ((ERROR_COUNT_OPT2++))
          rm -f gcloud_list_keys_stderr.log # 清理临时错误日志文件
          continue # 处理下一个项目
      fi
      rm -f gcloud_list_keys_stderr.log # 如果成功，也清理临时错误日志文件

      KEY_FOUND_IN_PROJECT=0 # 标记此项目中是否找到并处理了密钥
      # --- 修改后的 JQ 处理逻辑 ---
      # 检查 ALL_KEYS_JSON 是否为一个对象并且包含 .keys 数组。
      # -e 标志使 jq 在最后一个输出为 true/非空时以状态码 0 退出，否则以 1 退出。
      if echo "$ALL_KEYS_JSON" | jq -e 'type == "object" and (.keys | type == "array")' > /dev/null; then
          # 如果 .keys 存在并且是一个数组，则处理它。
          # 使用 .keys[] (没有 '?') 因为我们已经确认它存在并且是一个数组。
          echo "$ALL_KEYS_JSON" | jq -c '.keys[]' | while IFS= read -r key_json; do
              # 对空/null key_json 的检查通常在对有效数组使用 .keys[] 时不需要，但为了安全起见保留。
              if [ -z "$key_json" ] || [ "$key_json" == "null" ]; then continue; fi
              KEY_FOUND_IN_PROJECT=1 # 标记找到了密钥

              KEY_NAME=$(echo "$key_json" | jq -r '.name')
              KEY_DISPLAY_NAME=$(echo "$key_json" | jq -r '.displayName // "(无显示名称)"') # 处理 displayName 可能为空的情况
              KEY_UID=$(echo "$key_json" | jq -r '.uid')
              echo "    找到已存在密钥: 显示名称='$KEY_DISPLAY_NAME', 资源名='$KEY_NAME'"

              API_KEY_STRING_OPT2="获取密钥字符串失败" # 默认错误信息
              echo "      尝试获取 API 密钥字符串 (高风险操作！)..."
              FETCHED_KEY_STRING_OPT2=$(gcloud services api-keys get-key-string "$KEY_NAME" --project="$PROJECT_ID" --format='value(keyString)' 2>&1)
              GET_STRING_EXIT_CODE_OPT2=$?

              if [ $GET_STRING_EXIT_CODE_OPT2 -ne 0 ]; then
                  echo "      错误：获取密钥 '$KEY_NAME' 的 API 密钥字符串失败 (退出状态码: $GET_STRING_EXIT_CODE_OPT2)。"
                  echo "      错误详情: $FETCHED_KEY_STRING_OPT2"
                  if echo "$FETCHED_KEY_STRING_OPT2" | grep -q "caller does not have permission"; then # 判断是否因为权限不足
                      echo "        提示：可能缺少 'apikeys.keys.getKeyString' 权限。"
                  fi
                  ((GET_KEY_STRING_FAILED_COUNT_OPT2++))
              else
                  API_KEY_STRING_OPT2="$FETCHED_KEY_STRING_OPT2"
                  echo "      成功：已获取密钥 '$KEY_NAME' 的 API 密钥字符串 (请极其小心处理！)。"
              fi

              # 将找到的每个密钥的详细信息写入 CSV 文件 (选项 2)
              echo "\"$PROJECT_ID\",\"$KEY_DISPLAY_NAME\",\"$KEY_NAME\",\"$KEY_UID\",\"$API_KEY_STRING_OPT2\"" >> "$OPTION2_CSV_FILE"
              ((EXPORTED_EXISTING_COUNT++)) # 增加已导出密钥的计数
          done # 处理密钥的 while 循环结束
      else
          # ALL_KEYS_JSON 不是一个包含 .keys 数组的对象。
          # 这可能意味着它是 {} (空对象), [] (空数组), 或其他未被退出码捕获的错误 JSON 结构。
          echo "  信息：项目 '$PROJECT_ID' 的 JSON 响应中未找到 'keys' 数组，或者响应不是一个对象。"
          # 可选：如果意外触发此情况，可在此处打印原始 JSON 以进行调试：
          # echo "    项目 '$PROJECT_ID' 的原始 JSON 响应为: $ALL_KEYS_JSON"
      fi
      # --- 修改后的 JQ 处理逻辑结束 ---

      if [ $KEY_FOUND_IN_PROJECT -eq 0 ]; then
          # 这条消息现在会更准确，因为 KEY_FOUND_IN_PROJECT 仅在进入循环时（且 jq 成功解析出key_json时）设置。
          echo "  信息：项目 '$PROJECT_ID' 中未处理/找到 API 密钥。"
      else
          echo "  信息：已完成处理项目 '$PROJECT_ID' 中的已存在密钥。"
      fi
  fi # ACTION_MODE 条件判断结束

done
# --- 循环处理每个项目结束 ---
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
echo "重要提示：请在 Google Cloud Console 中验证结果。"
echo "重要提示：请极其小心地保护【所有包含 API 密钥字符串的输出文件】！"

exit 0 # 脚本正常结束
