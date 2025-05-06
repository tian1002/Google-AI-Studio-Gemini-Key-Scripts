#!/bin/bash

# --- 配置 ---
EXPECTED_KEY_PREFIX="Batch Created Key Restricted" # 选项 1 使用的前缀
TARGET_API_SERVICE="generativelanguage.googleapis.com" # 选项 1 使用的目标 API
CURRENT_DATETIME=$(date +%Y%m%d_%H%M%S)

# --- 文件名定义 ---
# !! 文件名现在都明确指出包含敏感密钥 !!
OPTION1_CSV_FILE="created_api_keys_with_secrets_${CURRENT_DATETIME}.csv"
OPTION2_CSV_FILE="all_existing_api_keys_WITH_SECRETS_${CURRENT_DATETIME}.csv" # !! 文件名已更改 !!
GCLOUD_LIST_STDERR_LOG="gcloud_list_stderr_${CURRENT_DATETIME}.log"

# (认证、权限)
# 确保认证，并拥有所需权限
# Option 1: create/update/getKeyString
# Option 2: list/getKeyString (需要能在所有项目上列出并获取所有密钥字符串的权限!)

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
echo

# --- 根据选择设置变量和执行操作 ---
case "$USER_CHOICE" in
    1)
        echo "选择操作 1: 创建并导出【新创建】的受限密钥 (包含密钥字符串)..."
        echo "!!! 输出文件: $OPTION1_CSV_FILE (包含敏感密钥)"
        # 初始化选项 1 的 CSV 文件
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
        # 初始化选项 2 的 CSV 文件 (添加 API Key String 列)
        echo "Project ID,Key Display Name,Key Resource Name,Key UID,API Key String" > "$OPTION2_CSV_FILE"
        ACTION_MODE="EXPORT_ALL_EXISTING_WITH_SECRETS" # 模式已更改
        ;;
    *)
        echo "无效的选择 '$USER_CHOICE'. 请输入 1 或 2."
        exit 1
        ;;
esac

echo "gcloud list errors (if any) will be saved to: $GCLOUD_LIST_STDERR_LOG"
# read -p "按 Enter 继续执行所选操作（包含高风险操作），按 Ctrl+C 中止..."

# --- 获取项目列表 ---
echo "Fetching active project list..."
PROJECT_IDS=$(gcloud projects list --filter="lifecycleState=ACTIVE" --format='value(project_id)' 2> "$GCLOUD_LIST_STDERR_LOG")
FETCH_EXIT_CODE=$?
# ... (调试信息和检查保持不变) ...
echo "--- DEBUG START ---"
echo "gcloud projects list exit code: $FETCH_EXIT_CODE"
echo "Contents of $GCLOUD_LIST_STDERR_LOG (if any):"
cat "$GCLOUD_LIST_STDERR_LOG"
echo "Raw content assigned to PROJECT_IDS variable (first 5 lines):"
echo "$PROJECT_IDS" | head -n 5
PROJECT_ID_COUNT=$(echo "$PROJECT_IDS" | wc -w)
echo "Word count (number of projects found in variable): $PROJECT_ID_COUNT"
echo "--- DEBUG END ---"
if [ $FETCH_EXIT_CODE -ne 0 ]; then echo "Error fetching project list..."; exit 1; fi
if [ "$PROJECT_ID_COUNT" -eq 0 ]; then echo "No active projects found."; exit 0; fi
echo "Found $PROJECT_ID_COUNT project IDs. Processing..."

# --- 初始化计数器 ---
# Option 1
SKIPPED_COUNT=0
CREATED_COUNT=0
ERROR_COUNT_OPT1=0
RESTRICTION_FAILED_COUNT=0
GET_KEY_STRING_FAILED_COUNT_OPT1=0
# Option 2
EXPORTED_EXISTING_COUNT=0
ERROR_COUNT_OPT2=0
GET_KEY_STRING_FAILED_COUNT_OPT2=0 # 新增 Option 2 获取字符串失败计数

# --- 循环处理每个项目 ---
echo "Attempting to enter the processing loop..."
PROJECT_COUNTER=0
for PROJECT_ID in $PROJECT_IDS
do
  PROJECT_COUNTER=$((PROJECT_COUNTER + 1))
  echo "--- LOOP ITERATION $PROJECT_COUNTER / $PROJECT_ID_COUNT ---"
  echo "-------------------------------------"
  echo "Processing project: $PROJECT_ID"

  if [ "$ACTION_MODE" == "CREATE_AND_EXPORT_NEW" ]; then
      # --- 选项 1 逻辑 (与上一版本包含密钥的 Option 1 相同) ---
      echo "  Action 1: Checking for prefix '$EXPECTED_KEY_PREFIX'..."
      # ... (检查、创建、更新、获取字符串、写入 Option 1 CSV 的逻辑保持不变) ...
      EXISTING_KEYS_OUTPUT=$(gcloud services api-keys list --project="$PROJECT_ID" --filter="displayName~'^$EXPECTED_KEY_PREFIX'" --format='value(name)' --limit=1 2>/dev/null)
      LIST_EXIT_CODE=$?
      if [ $LIST_EXIT_CODE -ne 0 ]; then
         echo "  Error listing keys for project $PROJECT_ID. Skipping."
         ((ERROR_COUNT_OPT1++))
         continue
      fi
      if [ ! -z "$EXISTING_KEYS_OUTPUT" ]; then
        echo "  Found existing key. Skipping creation."
        ((SKIPPED_COUNT++))
        continue
      else
        echo "  No existing key found. Creating..."
        CURRENT_DATE=$(date +%Y%m%d)
        KEY_DISPLAY_NAME="$EXPECTED_KEY_PREFIX - $CURRENT_DATE"
        KEY_OUTPUT=$(gcloud services api-keys create --project="$PROJECT_ID" --display-name="$KEY_DISPLAY_NAME" --format="json")
        CREATE_EXIT_CODE=$?
        if [ $CREATE_EXIT_CODE -ne 0 ]; then
            echo "  Error creating key. Skipping."
            ((ERROR_COUNT_OPT1++))
            continue
        else
            KEY_NAME=$(echo "$KEY_OUTPUT" | jq -r '.name')
            KEY_UID=$(echo "$KEY_OUTPUT" | jq -r '.uid')
            echo "    Key created: $KEY_NAME"
            UPDATE_OUTPUT=$(gcloud services api-keys update "$KEY_NAME" --project="$PROJECT_ID" --add-api-target="service=$TARGET_API_SERVICE" --format="json" 2>&1)
            UPDATE_EXIT_CODE=$?
            RESTRICTION_STATUS="Failed"
            if [ $UPDATE_EXIT_CODE -ne 0 ]; then
                echo "  Error applying restriction."
                ((RESTRICTION_FAILED_COUNT++))
            else
                RESTRICTION_STATUS="Success"
                echo "    Restriction applied."
            fi
            ((CREATED_COUNT++))
            API_KEY_STRING_OPT1="ERROR_FETCHING_KEY_STRING"
            echo "    Fetching key string..."
            FETCHED_KEY_STRING_OPT1=$(gcloud services api-keys get-key-string "$KEY_NAME" --project="$PROJECT_ID" --format='value(keyString)' 2>&1)
            GET_STRING_EXIT_CODE_OPT1=$?
            if [ $GET_STRING_EXIT_CODE_OPT1 -ne 0 ]; then
                echo "  Error fetching key string."
                ((GET_KEY_STRING_FAILED_COUNT_OPT1++))
            else
                API_KEY_STRING_OPT1="$FETCHED_KEY_STRING_OPT1"
                echo "    Key string fetched (Handle with care!)."
            fi
            echo "\"$PROJECT_ID\",\"$KEY_DISPLAY_NAME\",\"$KEY_NAME\",\"$KEY_UID\",\"$TARGET_API_SERVICE\",\"$RESTRICTION_STATUS\",\"$API_KEY_STRING_OPT1\"" >> "$OPTION1_CSV_FILE"
        fi
      fi

  elif [ "$ACTION_MODE" == "EXPORT_ALL_EXISTING_WITH_SECRETS" ]; then
      # --- 选项 2 逻辑: 导出所有已存在密钥 (包含密钥字符串) ---
      echo "  Action 2: Listing ALL existing keys for project $PROJECT_ID..."
      ALL_KEYS_JSON=$(gcloud services api-keys list --project="$PROJECT_ID" --format="json" 2> gcloud_list_keys_stderr.log)
      LIST_EXIT_CODE=$?
      if [ $LIST_EXIT_CODE -ne 0 ]; then
          # ... (错误处理同上一个脚本版本) ...
          echo "  Error listing keys for project $PROJECT_ID. Skipping project for Option 2."
          ((ERROR_COUNT_OPT2++))
          rm -f gcloud_list_keys_stderr.log
          continue
      fi
      rm -f gcloud_list_keys_stderr.log

      KEY_FOUND_IN_PROJECT=0
      echo "$ALL_KEYS_JSON" | jq -c '.keys[]?' | while IFS= read -r key_json; do
          if [ -z "$key_json" ] || [ "$key_json" == "null" ]; then continue; fi
          KEY_FOUND_IN_PROJECT=1

          KEY_NAME=$(echo "$key_json" | jq -r '.name')
          KEY_DISPLAY_NAME=$(echo "$key_json" | jq -r '.displayName // "(empty)"')
          KEY_UID=$(echo "$key_json" | jq -r '.uid')
          echo "    Found existing key: $KEY_DISPLAY_NAME ($KEY_NAME)"

          # --- !! 新增: 为选项 2 获取 API 密钥字符串 !! ---
          API_KEY_STRING_OPT2="ERROR_FETCHING_KEY_STRING" # 默认值
          echo "      Attempting to fetch API key string (High Risk Operation!)..."
          FETCHED_KEY_STRING_OPT2=$(gcloud services api-keys get-key-string "$KEY_NAME" --project="$PROJECT_ID" --format='value(keyString)' 2>&1)
          GET_STRING_EXIT_CODE_OPT2=$?

          if [ $GET_STRING_EXIT_CODE_OPT2 -ne 0 ]; then
              echo "      Error fetching API key string for $KEY_NAME. Check permissions (apikeys.keys.getKeyString)."
              echo "      Error details: $FETCHED_KEY_STRING_OPT2"
              ((GET_KEY_STRING_FAILED_COUNT_OPT2++))
              # API_KEY_STRING_OPT2 保持为错误信息
          else
              API_KEY_STRING_OPT2="$FETCHED_KEY_STRING_OPT2"
              echo "      Successfully fetched API key string for $KEY_NAME (Handle with extreme care!)."
          fi

          # --- !! 修改: 将密钥字符串写入 Option 2 CSV !! ---
          echo "\"$PROJECT_ID\",\"$KEY_DISPLAY_NAME\",\"$KEY_NAME\",\"$KEY_UID\",\"$API_KEY_STRING_OPT2\"" >> "$OPTION2_CSV_FILE"
          ((EXPORTED_EXISTING_COUNT++))
      done # 结束 jq 的 while 循环

      if [ $KEY_FOUND_IN_PROJECT -eq 0 ]; then
          echo "  No existing keys found in project $PROJECT_ID."
      else
          echo "  Finished processing existing keys for project $PROJECT_ID."
      fi
  fi # 结束 ACTION_MODE 判断

done
# --- 结束循环 ---
echo "Exited processing loop after $PROJECT_COUNTER iterations."

# --- 总结 ---
echo "====================================="
echo "Batch API key processing finished."

if [ "$ACTION_MODE" == "CREATE_AND_EXPORT_NEW" ]; then
    echo "--- Summary for Action 1 (Create & Export New) ---"
    echo "!!! WARNING: SENSITIVE API KEY STRINGS EXPORTED TO $OPTION1_CSV_FILE !!!"
    echo "-----------------------------------------------------------------------"
    # ... (Option 1 总结信息保持不变, 使用 OPT1 计数器) ...
    echo "  Projects Found by gcloud list: $PROJECT_ID_COUNT"
    echo "  Loop Iterations Started: $PROJECT_COUNTER"
    echo "  New Keys Successfully Created (step 1): $CREATED_COUNT"
    echo "  API Restriction Application Failed (step 2): $RESTRICTION_FAILED_COUNT"
    echo "  Fetching API Key String Failed (step 3): $GET_KEY_STRING_FAILED_COUNT_OPT1"
    echo "  Projects Skipped (existing key found): $SKIPPED_COUNT"
    echo "  Errors Encountered (listing, creation): $ERROR_COUNT_OPT1"
    echo "-------------------------------------"
    echo "Details of newly created keys exported to: $OPTION1_CSV_FILE"

elif [ "$ACTION_MODE" == "EXPORT_ALL_EXISTING_WITH_SECRETS" ]; then
    echo "--- Summary for Action 2 (Export ALL Existing WITH SECRETS) ---"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! HIGH RISK OUTPUT !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!! WARNING: SENSITIVE API KEY STRINGS FOR ALL LISTED KEYS EXPORTED TO:      !!!"
    echo "!!!          $OPTION2_CSV_FILE                                              !!!"
    echo "!!!          TREAT THIS FILE AS EXTREMELY CONFIDENTIAL! DELETE WHEN DONE.    !!!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "-------------------------------------------------------------------------------"
    echo "  Projects Found by gcloud list: $PROJECT_ID_COUNT"
    echo "  Loop Iterations Started: $PROJECT_COUNTER"
    echo "  Total Existing Keys Found: $EXPORTED_EXISTING_COUNT"
    echo "  Fetching API Key String Failed For: $GET_KEY_STRING_FAILED_COUNT_OPT2 keys" # 显示获取失败的计数
    echo "  Errors Encountered While Listing Keys: $ERROR_COUNT_OPT2"
    echo "-------------------------------------"
    echo "Details of ALL found existing keys (including strings) exported to: $OPTION2_CSV_FILE"
fi

echo "Errors from 'gcloud projects list' (if any) logged to: $GCLOUD_LIST_STDERR_LOG"
echo "IMPORTANT: Verify results in Google Cloud Console."
echo "IMPORTANT: SECURE ALL OUTPUT FILES CONTAINING KEY STRINGS EXTREMELY CAREFULLY!"

exit 0
