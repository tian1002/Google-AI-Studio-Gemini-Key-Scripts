#!/bin/bash

# --- 配置 ---
EXPECTED_KEY_PREFIX="Batch Created Key Restricted" # 选项 1 使用的前缀
# !! 根据你的需要，确认或修改目标 API 服务 !!
TARGET_API_SERVICE="generativelanguage.googleapis.com" # 独立的 GenAI API
#TARGET_API_SERVICE="aiplatform.googleapis.com"         # Vertex AI API (推荐)

# 定义需要确保启用的 API (两个选项都会用到)
# 包括目标服务 API 和 API Keys API 本身
APIS_TO_ENABLE_FOR_KEYS="$TARGET_API_SERVICE apikeys.googleapis.com"

CURRENT_DATETIME=$(date +%Y%m%d_%H%M%S) # 当前日期和时间

# --- 文件名定义 ---
OPTION1_CSV_FILE="created_api_keys_with_secrets_${CURRENT_DATETIME}.csv"
OPTION2_CSV_FILE="all_existing_api_keys_WITH_SECRETS_${CURRENT_DATETIME}.csv"
GCLOUD_LIST_STDERR_LOG="gcloud_list_stderr_${CURRENT_DATETIME}.log"

# --- (认证与权限) ---
# 确保您已经通过 `gcloud auth login` 进行了认证，并且拥有必要的权限。
# !! 注意：现在两个选项都需要启用服务的权限 !!
# 选项 1 需要权限: roles/serviceusage.serviceUsageAdmin, roles/apikeys.creator, roles/apikeys.updater, apikeys.keys.getKeyString (或更高)
# 选项 2 需要权限: roles/serviceusage.serviceUsageAdmin, roles/apikeys.viewer, apikeys.keys.list, apikeys.keys.getKeyString (或更高)

# --- 获取用户选择 ---
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!!!                          重要安全警告                                  !!!"
echo "!!!   脚本将导出【包含敏感 API 密钥字符串】的 CSV 文件。                   !!!"
echo "!!!   泄露将导致严重安全风险！ 请在完全了解并接受风险的情况下继续。        !!!"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "--------------------------------------------------"
echo "请选择要执行的操作："
echo "  1. 【启用 API】并创建缺失的受限密钥 (前缀: '$EXPECTED_KEY_PREFIX', 限制: '$TARGET_API_SERVICE')，"
echo "     并导出本次【新创建】密钥的详细信息 (包含 API 密钥字符串)。"
echo "  2. 【启用 API】并扫描所有活动项目中的【所有】已存在 API 密钥，" # 更新描述
echo "     并导出它们的详细信息 (【包含 API 密钥字符串 - 极高风险!】)。"
echo "--------------------------------------------------"
read -p "请输入你的选择 (1 或 2): " USER_CHOICE
echo

# --- 根据用户选择设置变量和执行操作 ---
case "$USER_CHOICE" in
    1)
        echo "选择操作 1: 启用 API、创建并导出【新创建】的受限密钥 (包含密钥字符串)..."
        echo "!!! 输出文件: $OPTION1_CSV_FILE (包含敏感密钥)"
        echo "Project ID,Key Display Name,Key Resource Name,Key UID,Restricted To API,Restriction Status,API Key String" > "$OPTION1_CSV_FILE"
        ACTION_MODE="CREATE_AND_EXPORT_NEW"
        ;;
    2)
        echo "选择操作 2: 启用 API、导出【所有已存在】API 密钥的详细信息 (包含密钥字符串)..." # 更新描述
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
        exit 1
        ;;
esac

echo "gcloud projects list 命令的错误 (如果有) 将会保存在: $GCLOUD_LIST_STDERR_LOG"
# read -p "按 Enter 继续执行所选操作（包含高风险操作），按 Ctrl+C 中止..."

# --- 获取项目列表 ---
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
if [ $FETCH_EXIT_CODE -ne 0 ]; then echo "获取项目列表时出错..."; exit 1; fi
if [ "$PROJECT_ID_COUNT" -eq 0 ]; then echo "未找到活动项目。"; exit 0; fi
echo "找到了 $PROJECT_ID_COUNT 个项目ID。开始处理..."

# --- 初始化计数器 (添加全局 API 启用失败计数) ---
API_ENABLE_FAILED_COUNT=0 # API 启用失败总计数 (跨选项)
# 选项 1
SKIPPED_COUNT=0
CREATED_COUNT=0
ERROR_COUNT_OPT1=0
RESTRICTION_FAILED_COUNT=0
GET_KEY_STRING_FAILED_COUNT_OPT1=0
# 选项 2
EXPORTED_EXISTING_COUNT=0
ERROR_COUNT_OPT2=0
GET_KEY_STRING_FAILED_COUNT_OPT2=0

# --- 循环处理每个项目 ---
echo "尝试进入项目处理循环..."
PROJECT_COUNTER=0
for PROJECT_ID in $PROJECT_IDS
do
  PROJECT_COUNTER=$((PROJECT_COUNTER + 1))
  echo "--- 循环迭代 $PROJECT_COUNTER / $PROJECT_ID_COUNT ---"
  echo "-------------------------------------"
  echo "正在处理项目: $PROJECT_ID"

  # --- 公共步骤：尝试启用所需 API (现在两个选项都需要) ---
  # 如果是选项1，只在需要创建时启用；如果是选项2，每次都尝试启用（gcloud enable 是幂等的）
  ENABLE_APIS_FOR_THIS_PROJECT=false # 标记是否需要执行启用操作
  if [ "$ACTION_MODE" == "EXPORT_ALL_EXISTING_WITH_SECRETS" ]; then
      ENABLE_APIS_FOR_THIS_PROJECT=true
      echo "  操作 2: 尝试启用所需 API: $APIS_TO_ENABLE_FOR_KEYS ..."
  elif [ "$ACTION_MODE" == "CREATE_AND_EXPORT_NEW" ]; then
      # 选项1：先检查密钥是否存在，只在需要创建时才启用 API
      echo "  操作 1: 检查项目 '$PROJECT_ID' 中是否存在前缀为 '$EXPECTED_KEY_PREFIX' 的密钥..."
      EXISTING_KEYS_OUTPUT=$(gcloud services api-keys list --project="$PROJECT_ID" --filter="displayName~'^$EXPECTED_KEY_PREFIX'" --format='value(name)' --limit=1 2> gcloud_list_keys_stderr.log)
      LIST_EXIT_CODE=$?
      if [ $LIST_EXIT_CODE -ne 0 ]; then
         LIST_KEYS_STDERR=$(cat gcloud_list_keys_stderr.log)
         if echo "$LIST_KEYS_STDERR" | grep -q "ApiKeys API is not enabled"; then
             echo "  信息：ApiKeys API 未启用。将在下一步尝试启用..."
             ENABLE_APIS_FOR_THIS_PROJECT=true # 需要启用
         else
             echo "  错误：列出项目 '$PROJECT_ID' 中的密钥失败。跳过此项目。"
             echo "    错误详情: $LIST_KEYS_STDERR"
             ((ERROR_COUNT_OPT1++))
             rm -f gcloud_list_keys_stderr.log
             continue # 跳过此项目
         fi
      fi
      rm -f gcloud_list_keys_stderr.log

      if [ ! -z "$EXISTING_KEYS_OUTPUT" ]; then
        echo "  信息：找到已存在符合前缀的密钥。跳过启用和创建。"
        ((SKIPPED_COUNT++))
        # ENABLE_APIS_FOR_THIS_PROJECT 保持 false
      else
        echo "  信息：未找到符合前缀的密钥。需要启用 API 并创建..."
        ENABLE_APIS_FOR_THIS_PROJECT=true # 需要启用
      fi
  fi

  # --- 执行 API 启用 (如果标记为需要) ---
  API_ENABLE_SUCCESS=true # 假设成功，除非下面步骤失败
  if [ "$ENABLE_APIS_FOR_THIS_PROJECT" = true ]; then
      echo "  步骤 0: 尝试启用 API: $APIS_TO_ENABLE_FOR_KEYS ..."
      ENABLE_APIS_OUTPUT=$(gcloud services enable $APIS_TO_ENABLE_FOR_KEYS --project="$PROJECT_ID" 2>&1)
      ENABLE_APIS_EXIT_CODE=$?
      if [ $ENABLE_APIS_EXIT_CODE -ne 0 ]; then
          echo "  错误：在项目 '$PROJECT_ID' 中启用所需 API 失败 (退出码: $ENABLE_APIS_EXIT_CODE)。"
          echo "    错误详情: $ENABLE_APIS_OUTPUT"
          if echo "$ENABLE_APIS_OUTPUT" | grep -q -i "permission denied"; then
              echo "    提示：请检查您在此项目上的 'serviceusage.services.enable' 权限。"
          elif echo "$ENABLE_APIS_OUTPUT" | grep -q -i "billing account"; then
              echo "    提示：启用此(些) API 可能需要有效的结算帐号。"
          fi
          ((API_ENABLE_FAILED_COUNT++)) # 增加全局失败计数
          API_ENABLE_SUCCESS=false       # 标记此项目 API 启用失败
          # 根据模式增加特定错误计数并决定是否继续
          if [ "$ACTION_MODE" == "CREATE_AND_EXPORT_NEW" ]; then
              ((ERROR_COUNT_OPT1++))
              echo "    提示：跳过在此项目中创建 API 密钥。"
              continue # 选项1：启用失败则跳过后续创建
          elif [ "$ACTION_MODE" == "EXPORT_ALL_EXISTING_WITH_SECRETS" ]; then
              ((ERROR_COUNT_OPT2++))
              echo "    提示：跳过在此项目中列出和导出 API 密钥。"
              continue # 选项2：启用失败也跳过后续列出
          fi
      else
          echo "  成功：所需 API ($APIS_TO_ENABLE_FOR_KEYS) 已启用或已成功启用。"
      fi
  fi

  # --- 如果 API 启用成功 (或不需要启用)，则继续执行相应模式的操作 ---
  if [ "$API_ENABLE_SUCCESS" = true ]; then
      if [ "$ACTION_MODE" == "CREATE_AND_EXPORT_NEW" ]; then
          # 选项1：执行创建密钥逻辑 (仅当 ENABLE_APIS_FOR_THIS_PROJECT 为 true 时才会执行到这里)
          if [ "$ENABLE_APIS_FOR_THIS_PROJECT" = true ]; then
              CURRENT_DATE=$(date +%Y%m%d)
              KEY_DISPLAY_NAME="$EXPECTED_KEY_PREFIX - $CURRENT_DATE"
              echo "  步骤 1: 尝试创建 API 密钥 '$KEY_DISPLAY_NAME'..."
              # ... (创建、更新、获取字符串、写入 CSV 的逻辑 - 同前) ...
              KEY_OUTPUT=$(gcloud services api-keys create --project="$PROJECT_ID" --display-name="$KEY_DISPLAY_NAME" --format="json")
              CREATE_EXIT_CODE=$?
              if [ $CREATE_EXIT_CODE -ne 0 ]; then echo "  错误：创建密钥失败..."; ((ERROR_COUNT_OPT1++)); continue; fi
              KEY_NAME=$(echo "$KEY_OUTPUT" | jq -r '.name'); KEY_UID=$(echo "$KEY_OUTPUT" | jq -r '.uid'); echo "    成功：密钥已创建: $KEY_NAME"
              echo "  步骤 2: 尝试应用限制 '$TARGET_API_SERVICE'..."
              UPDATE_OUTPUT=$(gcloud services api-keys update "$KEY_NAME" --project="$PROJECT_ID" --add-api-target="service=$TARGET_API_SERVICE" --format="json" 2>&1); UPDATE_EXIT_CODE=$?
              RESTRICTION_STATUS="失败"; if [ $UPDATE_EXIT_CODE -ne 0 ]; then echo "  错误：应用限制失败。"; ((RESTRICTION_FAILED_COUNT++)); else RESTRICTION_STATUS="成功"; echo "    成功：限制已应用。"; fi; ((CREATED_COUNT++))
              API_KEY_STRING_OPT1="获取密钥字符串失败"; echo "  步骤 3: 尝试获取密钥字符串..."; FETCHED_KEY_STRING_OPT1=$(gcloud services api-keys get-key-string "$KEY_NAME" --project="$PROJECT_ID" --format='value(keyString)' 2>&1); GET_STRING_EXIT_CODE_OPT1=$?
              if [ $GET_STRING_EXIT_CODE_OPT1 -ne 0 ]; then echo "  错误：获取字符串失败。"; ((GET_KEY_STRING_FAILED_COUNT_OPT1++)); else API_KEY_STRING_OPT1="$FETCHED_KEY_STRING_OPT1"; echo "    成功：字符串已获取。"; fi
              echo "\"$PROJECT_ID\",\"$KEY_DISPLAY_NAME\",\"$KEY_NAME\",\"$KEY_UID\",\"$TARGET_API_SERVICE\",\"$RESTRICTION_STATUS\",\"$API_KEY_STRING_OPT1\"" >> "$OPTION1_CSV_FILE"
          else
              # 这个分支理论上不应该执行到，因为如果密钥存在，会先 continue
              echo "  (内部逻辑错误：API 启用未标记为需要，但不应执行到创建步骤)"
          fi

      elif [ "$ACTION_MODE" == "EXPORT_ALL_EXISTING_WITH_SECRETS" ]; then
          # 选项 2：执行列出所有密钥的逻辑
          echo "  操作 2 (续): 列出项目 '$PROJECT_ID' 中的【所有】已存在密钥..."
          # ... (列出、JQ 处理、获取字符串、写入 Option 2 CSV 的逻辑 - 同前) ...
          ALL_KEYS_JSON=$(gcloud services api-keys list --project="$PROJECT_ID" --format="json" 2> gcloud_list_keys_stderr.log); LIST_EXIT_CODE=$?
          if [ $LIST_EXIT_CODE -ne 0 ]; then echo "  错误：再次列出密钥失败..."; ((ERROR_COUNT_OPT2++)); rm -f gcloud_list_keys_stderr.log; continue; fi; rm -f gcloud_list_keys_stderr.log
          KEY_FOUND_IN_PROJECT=0
          if echo "$ALL_KEYS_JSON" | jq -e 'type == "array"' > /dev/null; then
              echo "$ALL_KEYS_JSON" | jq -c '.[]?' | while IFS= read -r key_json; do
                  if [ -z "$key_json" ] || [ "$key_json" == "null" ]; then continue; fi
                  KEY_FOUND_IN_PROJECT=1
                  KEY_NAME=$(echo "$key_json" | jq -r '.name'); if [ -z "$KEY_NAME" ] || [ "$KEY_NAME" == "null" ]; then continue; fi
                  KEY_DISPLAY_NAME=$(echo "$key_json" | jq -r '.displayName // "(无显示名称)"'); KEY_UID=$(echo "$key_json" | jq -r '.uid // "(未知UID)"'); echo "    找到密钥: '$KEY_DISPLAY_NAME' ($KEY_NAME)"
                  API_KEY_STRING_OPT2="获取密钥字符串失败"; echo "      获取字符串..."; FETCHED_KEY_STRING_OPT2=$(gcloud services api-keys get-key-string "$KEY_NAME" --project="$PROJECT_ID" --format='value(keyString)' 2>&1); GET_STRING_EXIT_CODE_OPT2=$?
                  if [ $GET_STRING_EXIT_CODE_OPT2 -ne 0 ]; then echo "      错误：获取字符串失败。"; ((GET_KEY_STRING_FAILED_COUNT_OPT2++)); else API_KEY_STRING_OPT2="$FETCHED_KEY_STRING_OPT2"; echo "      成功：字符串已获取。"; fi
                  echo "\"$PROJECT_ID\",\"$KEY_DISPLAY_NAME\",\"$KEY_NAME\",\"$KEY_UID\",\"$API_KEY_STRING_OPT2\"" >> "$OPTION2_CSV_FILE"; ((EXPORTED_EXISTING_COUNT++))
              done
          else
              echo "  信息：项目 '$PROJECT_ID' 的 JSON 响应不是预期的密钥数组。"; echo "    原始响应: $ALL_KEYS_JSON"
          fi
          if [ $KEY_FOUND_IN_PROJECT -eq 0 ]; then echo "  信息：项目中未找到或未处理密钥。"; else echo "  信息：项目处理完成。"; fi
      fi
  fi # 结束 API_ENABLE_SUCCESS 的判断

done
# --- 循环处理每个项目结束 ---
echo "已退出项目处理循环，共迭代 $PROJECT_COUNTER 次。"

# --- 总结 ---
echo "====================================="
echo "批量 API 密钥处理操作已完成。"
echo "API 启用失败的项目总数 (所有选项): $API_ENABLE_FAILED_COUNT" # 显示全局启用失败计数
echo "====================================="

if [ "$ACTION_MODE" == "CREATE_AND_EXPORT_NEW" ]; then
    echo "--- 操作 1 总结 (启用 API、创建并导出新密钥) ---"
    echo "!!! 警告: 包含敏感 API 密钥字符串的文件已导出至 $OPTION1_CSV_FILE !!!"
    echo "-----------------------------------------------------------------------"
    echo "  项目总数: $PROJECT_ID_COUNT, 循环次数: $PROJECT_COUNTER"
    echo "  成功创建密钥数: $CREATED_COUNT"
    echo "  限制应用失败数: $RESTRICTION_FAILED_COUNT"
    echo "  获取新密钥字符串失败数: $GET_KEY_STRING_FAILED_COUNT_OPT1"
    echo "  API 启用失败跳过数 (计入下面错误总数): $API_ENABLE_FAILED_COUNT" # 在选项1总结中也显示
    echo "  因密钥已存在跳过数: $SKIPPED_COUNT"
    echo "  遇到的总错误数 (启用/列出/创建失败): $ERROR_COUNT_OPT1"
    echo "-------------------------------------"
    echo "新创建密钥的详细信息已导出至: $OPTION1_CSV_FILE"

elif [ "$ACTION_MODE" == "EXPORT_ALL_EXISTING_WITH_SECRETS" ]; then
    echo "--- 操作 2 总结 (启用 API、导出所有密钥及字符串) ---" # 更新总结标题
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! 高风险输出 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!! 警告: 包含【所有】列出密钥的敏感 API 密钥字符串的文件已导出至:     !!!"
    echo "!!!          $OPTION2_CSV_FILE                                              !!!"
    echo "!!!          请将此文件视为【最高机密】！使用完毕后立即安全删除！          !!!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "-------------------------------------------------------------------------------"
    echo "  项目总数: $PROJECT_ID_COUNT, 循环次数: $PROJECT_COUNTER"
    echo "  找到并导出的已存在密钥总数: $EXPORTED_EXISTING_COUNT"
    echo "  获取已存在密钥字符串失败数: $GET_KEY_STRING_FAILED_COUNT_OPT2"
    echo "  API 启用失败跳过数 (计入下面错误总数): $API_ENABLE_FAILED_COUNT" # 在选项2总结中也显示
    echo "  列出密钥时错误跳过数: $ERROR_COUNT_OPT2"
    echo "-------------------------------------"
    echo "【所有】找到的已存在密钥的详细信息 (包含密钥字符串) 已导出至: $OPTION2_CSV_FILE"
fi

echo "gcloud projects list 命令的错误 (如果有) 已记录到: $GCLOUD_LIST_STDERR_LOG"
echo "重要提示：请在 Google Cloud Console 中验证结果。"
echo "重要提示：API 启用后，相关服务可能需要结算账户支持才能使用。"
echo "重要提示：请极其小心地保护【所有包含 API 密钥字符串的输出文件】！"

exit 0
