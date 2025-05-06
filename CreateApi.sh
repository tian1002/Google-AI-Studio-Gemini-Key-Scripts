#!/bin/bash

# --- 配置 ---
EXPECTED_KEY_PREFIX="Batch Created Key Restricted" # 可选：更新前缀以反映限制
TARGET_API_SERVICE="generativelanguage.googleapis.com" # 要限制的目标 API 服务
CURRENT_DATETIME=$(date +%Y%m%d_%H%M%S)
OUTPUT_CSV_FILE="created_api_keys_${CURRENT_DATETIME}.csv" # 导出 CSV 文件名
GCLOUD_LIST_STDERR_LOG="gcloud_list_stderr_${CURRENT_DATETIME}.log" # gcloud list 的错误日志

# (认证、权限)
# 确保您已经通过 `gcloud auth login` 进行了认证，并且拥有必要的权限。

# --- 初始化输出文件 ---
# Added Restriction Status column
echo "Project ID,Key Display Name,Key Resource Name,Key UID,Restricted To API,Restriction Status" > "$OUTPUT_CSV_FILE"
echo "Output CSV will be saved to: $OUTPUT_CSV_FILE"
echo "gcloud list errors (if any) will be saved to: $GCLOUD_LIST_STDERR_LOG"

# --- 获取项目列表 ---
echo "Fetching active project list..."
# 在捕获 stdout 的同时，将 stderr 重定向到日志文件以便检查
PROJECT_IDS=$(gcloud projects list --filter="lifecycleState=ACTIVE" --format='value(project_id)' 2> "$GCLOUD_LIST_STDERR_LOG")
FETCH_EXIT_CODE=$? # 捕获 gcloud list 的退出码

# --- 添加调试行 ---
echo "--- DEBUG START ---"
echo "gcloud projects list exit code: $FETCH_EXIT_CODE"
echo "Contents of $GCLOUD_LIST_STDERR_LOG (if any):"
cat "$GCLOUD_LIST_STDERR_LOG" # 显示 gcloud list 可能输出到 stderr 的任何内容
echo "Raw content assigned to PROJECT_IDS variable (first 5 lines):"
echo "$PROJECT_IDS" | head -n 5 # 只显示前5行，避免输出过长
PROJECT_ID_COUNT=$(echo "$PROJECT_IDS" | wc -w) # 计算获取到的项目 ID 数量
echo "Word count (number of projects found in variable): $PROJECT_ID_COUNT"
echo "--- DEBUG END ---"
# --- 结束调试行 ---

# 检查 gcloud 命令是否成功执行
if [ $FETCH_EXIT_CODE -ne 0 ]; then
  echo "Error fetching project list (Exit Code: $FETCH_EXIT_CODE). Check stderr log file '$GCLOUD_LIST_STDERR_LOG' and permissions."
  # 如果获取列表失败，可以选择退出
  # exit 1
fi

# 检查变量是否真的为空 (即使退出码为0，也可能没有返回项目)
if [ "$PROJECT_ID_COUNT" -eq 0 ]; then
   # 这解释了为什么循环可能不执行
   echo "No active projects were assigned to the PROJECT_IDS variable inside the script."
   # 脚本会继续执行到总结部分，报告处理了0个项目
else
    echo "Found $PROJECT_ID_COUNT project IDs assigned to variable. Should start processing loop..."
fi

# --- 初始化计数器 ---
SKIPPED_COUNT=0
CREATED_COUNT=0
ERROR_COUNT=0
RESTRICTION_FAILED_COUNT=0 # New counter for restriction errors

# --- 循环处理每个项目 ---
echo "Attempting to enter the processing loop..." # 增加进入循环前的日志
PROJECT_COUNTER=0 # 初始化项目计数器
for PROJECT_ID in $PROJECT_IDS
do
  PROJECT_COUNTER=$((PROJECT_COUNTER + 1)) # 每次循环计数器加1
  echo "--- LOOP ITERATION $PROJECT_COUNTER / $PROJECT_ID_COUNT ---" # 标记循环次数
  echo "-------------------------------------"
  echo "Processing project: $PROJECT_ID"

  # --- 检查是否存在具有特定前缀的密钥 ---
  echo "  Checking for existing keys with prefix '$EXPECTED_KEY_PREFIX'..."
  # 注意：下面的 WARNING 是 gcloud 在找不到任何匹配项时的正常行为，可以忽略
  # 将 list 的 stderr 也重定向，避免干扰正常输出
  EXISTING_KEYS_OUTPUT=$(gcloud services api-keys list \
                          --project="$PROJECT_ID" \
                          --filter="displayName~'^$EXPECTED_KEY_PREFIX'" \
                          --format='value(name)' \
                          --limit=1 2>/dev/null) # Redirect stderr to hide the benign warning

  LIST_EXIT_CODE=$?
  # 检查退出码和特定错误消息
  if [ $LIST_EXIT_CODE -ne 0 ]; then
     # 尝试捕获实际错误，即使退出了0，API也可能被禁用
     LIST_ERROR_CHECK=$(gcloud services api-keys list --project="$PROJECT_ID" --limit=1 2>&1)
     if echo "$LIST_ERROR_CHECK" | grep -q "ApiKeys API is not enabled"; then
        echo "  Info: API Keys API not enabled for project $PROJECT_ID. Skipping."
     elif echo "$LIST_ERROR_CHECK" | grep -q "consumer does not have access"; then
        echo "  Error: Permission denied listing keys for project $PROJECT_ID. Skipping."
     else
        echo "  Error listing keys for project $PROJECT_ID (Exit Code: $LIST_EXIT_CODE). Output/Error: $LIST_ERROR_CHECK. Skipping."
     fi
     ((ERROR_COUNT++))
     continue # 跳到下一个项目
  fi

  # 检查是否有找到密钥 (变量非空)
  if [ ! -z "$EXISTING_KEYS_OUTPUT" ]; then
    echo "  Found existing key(s) matching prefix '$EXPECTED_KEY_PREFIX'. Skipping creation."
    ((SKIPPED_COUNT++))
    continue # 跳到下一个项目
  else
    echo "  No existing restricted keys found with the prefix. Proceeding..."

    # --- (可选) 启用 API ---
    # ... (如果需要，在这里添加启用 API 的逻辑) ...

    # --- 步骤 1: 创建 API 密钥 (无限制) ---
    CURRENT_DATE=$(date +%Y%m%d) # 日期可以在循环外获取一次，如果都一样的话
    KEY_DISPLAY_NAME="$EXPECTED_KEY_PREFIX - $CURRENT_DATE"
    echo "  Attempting to create API key '$KEY_DISPLAY_NAME' (without restrictions initially)..."

    # 执行创建命令，捕获 json 输出
    KEY_OUTPUT=$(gcloud services api-keys create \
      --project="$PROJECT_ID" \
      --display-name="$KEY_DISPLAY_NAME" \
      --format="json")
    CREATE_EXIT_CODE=$?

    if [ $CREATE_EXIT_CODE -ne 0 ]; then
      echo "  Error creating key (step 1) for project $PROJECT_ID. Exit Code: $CREATE_EXIT_CODE."
      # 如果 KEY_OUTPUT 包含 JSON 错误结构，尝试解析
      ERROR_MESSAGE=$(echo "$KEY_OUTPUT" | jq -r '.error.message' 2>/dev/null)
      if [ -z "$ERROR_MESSAGE" ] || [ "$ERROR_MESSAGE" == "null" ]; then
         # 如果解析失败或没有错误消息，显示原始命令输出（可能非JSON）
         # 重新运行以捕获 stderr
         RAW_ERROR_OUTPUT=$(gcloud services api-keys create --project="$PROJECT_ID" --display-name="$KEY_DISPLAY_NAME" 2>&1 >/dev/null)
         ERROR_MESSAGE="Raw gcloud error: $RAW_ERROR_OUTPUT"
      fi

      echo "    Error Detail: $ERROR_MESSAGE"
      # 添加具体提示
      if echo "$ERROR_MESSAGE" | grep -q "caller does not have permission"; then
        echo "    Hint: Caller might lack 'apikeys.keys.create' permission on project $PROJECT_ID."
      elif echo "$ERROR_MESSAGE" | grep -q "ApiKeys API is not enabled"; then
        echo "    Hint: The API Keys API (apikeys.googleapis.com) might need to be enabled for project $PROJECT_ID."
      fi
      ((ERROR_COUNT++))
      continue # Skip to the next project if creation failed
    else
      # 解析成功的 JSON 输出
      KEY_NAME=$(echo "$KEY_OUTPUT" | jq -r '.name') # projects/PROJECT_NUMBER/locations/global/keys/KEY_ID
      KEY_UID=$(echo "$KEY_OUTPUT" | jq -r '.uid')
      echo "    Successfully created key (step 1)."
      echo "      Key Display Name: $KEY_DISPLAY_NAME"
      echo "      Key Resource Name: $KEY_NAME"
      echo "      Key UID: $KEY_UID"

      # --- 步骤 2: 更新密钥以添加 API 限制 ---
      echo "  Attempting to apply API restriction (step 2): Allow only '$TARGET_API_SERVICE'..."
      # 执行更新命令，同时捕获 stdout 和 stderr
      UPDATE_OUTPUT=$(gcloud services api-keys update "$KEY_NAME" \
        --project="$PROJECT_ID" \
        --add-api-target="service=$TARGET_API_SERVICE" \
        --format="json" 2>&1) # Capture stderr as well
      UPDATE_EXIT_CODE=$?
      RESTRICTION_STATUS="Failed" # Default status

      if [ $UPDATE_EXIT_CODE -ne 0 ]; then
        echo "  Error applying API restriction (step 2) for key $KEY_NAME in project $PROJECT_ID. Exit Code: $UPDATE_EXIT_CODE."
        echo "    Update command output/error: $UPDATE_OUTPUT" # Display raw output from update command

        # 添加具体提示
        if echo "$UPDATE_OUTPUT" | grep -q "Permission denied on service" || echo "$UPDATE_OUTPUT" | grep -q "needs to be enabled"; then
           echo "    Hint: The target API '$TARGET_API_SERVICE' might not be enabled in project $PROJECT_ID, or you lack 'serviceusage.services.use' permission."
        elif echo "$UPDATE_OUTPUT" | grep -q "caller does not have permission"; then
           echo "    Hint: Caller might lack 'apikeys.keys.update' permission on the key or project."
        fi
        ((RESTRICTION_FAILED_COUNT++))
        # Key was created, but restriction failed. Still count as created but log the failure.
        ((CREATED_COUNT++)) # Count creation as successful even if restriction fails
      else
        echo "    Successfully applied API restriction '$TARGET_API_SERVICE'."
        RESTRICTION_STATUS="Success"
        ((CREATED_COUNT++)) # Count creation+restriction as successful overall creation
      fi

      # --- 将创建的密钥信息追加到 CSV 文件 ---
      # 使用双引号确保包含特殊字符的字段正确写入 CSV
      echo "\"$PROJECT_ID\",\"$KEY_DISPLAY_NAME\",\"$KEY_NAME\",\"$KEY_UID\",\"$TARGET_API_SERVICE\",\"$RESTRICTION_STATUS\"" >> "$OUTPUT_CSV_FILE"
    fi
  fi
done
# --- 结束循环 ---
echo "Exited processing loop after $PROJECT_COUNTER iterations." # 增加退出循环后的日志

# --- 总结 ---
echo "====================================="
echo "Batch restricted API key creation process finished."
echo "Summary:"
# 使用之前计算好的 $PROJECT_ID_COUNT 作为处理的总项目数（如果 gcloud list 成功）
# 或者使用循环计数器 $PROJECT_COUNTER 作为实际进入循环的项目数
echo "  Projects Found by gcloud list: $PROJECT_ID_COUNT"
echo "  Loop Iterations Started: $PROJECT_COUNTER"
echo "  Keys Successfully Created (step 1): $CREATED_COUNT"
echo "     (Note: This count includes keys where the restriction step might have failed)"
echo "  API Restriction Application Failed (step 2): $RESTRICTION_FAILED_COUNT"
echo "  Projects Skipped (existing key found): $SKIPPED_COUNT"
echo "  Errors Encountered (listing keys, initial creation failure, etc.): $ERROR_COUNT"
echo "-------------------------------------"
echo "Created API key details have been exported to: $OUTPUT_CSV_FILE"
echo "Errors from 'gcloud projects list' (if any) logged to: $GCLOUD_LIST_STDERR_LOG"
echo "IMPORTANT: Review the 'Restriction Status' column in the CSV."
echo "IMPORTANT: Verify keys and restrictions in Google Cloud Console."
echo "IMPORTANT: The actual API key strings are NOT included in the CSV for security reasons."
echo "If you need the key string, use 'gcloud services api-keys get-key-string projects/PROJECT_NUMBER/locations/global/keys/KEY_ID --project=PROJECT_ID'."
echo "Secure all credentials appropriately."

exit 0 # 脚本正常结束
