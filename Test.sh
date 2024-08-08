#!/bin/bash

BASE_DIR="/home/sub"
if [ ! -d "$BASE_DIR" ]; then
  mkdir -p "$BASE_DIR"
  if [ $? -ne 0 ]; then
    echo "无法创建目录 $BASE_DIR，请检查权限。"
    exit 1
  fi
fi

read -p "请输入 TELEGRAM_BOT_TOKEN: " TELEGRAM_BOT_TOKEN
read -p "请输入 CHAT_ID: " CHAT_ID

read -p "请输入生成的tocken数量 (默认: 5000): " TOKEN_COUNT
TOKEN_COUNT=${TOKEN_COUNT:-5000}

read -p "请输入尝试写入文件上限 (默认: 99): " MAX_RETRIES
MAX_RETRIES=${MAX_RETRIES:-99}

read -p "请输入尝试写入文件间隔 (秒) (默认: 5): " RETRY_DELAY
RETRY_DELAY=${RETRY_DELAY:-5}

read -p "请输入脚本执行次数 (默认: 10000): " LOOP_COUNT
LOOP_COUNT=${LOOP_COUNT:-10000}

generate_token() {
  tr -dc 'a-z0-9' < /dev/urandom | head -c 31
}

write_with_retry() {
  local file=$1
  local content=$2
  local retries=0
  while true; do
    echo "$content" >> "$file"
    if [ $? -eq 0 ]; then
      break
    else
      retries=$((retries + 1))
      if [ $retries -ge $MAX_RETRIES ]; then
        echo "无法写入到 $file, 达到最大重试次数" >> "$LOG_FILE"
        return 1
      fi
      sleep $RETRY_DELAY
    fi
  done
  return 0
}

TOKEN_FILE="$BASE_DIR/tokens.txt"
SUCCESS_FILE="$BASE_DIR/success.txt"
FAIL_FILE="$BASE_DIR/fail.txt"
LOG_FILE="$BASE_DIR/error.log"

run_script() {
  mkdir -p "$BASE_DIR" 2>> "$LOG_FILE"
  if [ $? -ne 0 ]; then
    echo "无法创建目录 $BASE_DIR" | tee -a "$LOG_FILE"
  fi
  echo "确保目录存在: $BASE_DIR"

  touch "$TOKEN_FILE" "$SUCCESS_FILE" "$FAIL_FILE" 2>> "$LOG_FILE"
  if [ $? -ne 0 ]; then
    echo "无法创建文件 $TOKEN_FILE 或 $SUCCESS_FILE 或 $FAIL_FILE" | tee -a "$LOG_FILE"
  fi
  echo "确保文件存在: $TOKEN_FILE, $SUCCESS_FILE, $FAIL_FILE"

  declare -A token_map
  if [ -f "$TOKEN_FILE" ]; then
    while read -r token; do
      token_map["$token"]=1
    done < "$TOKEN_FILE"
  fi

  declare -A success_map
  declare -A fail_map

  if [ -f "$SUCCESS_FILE" ]; then
    while read -r token; do
      success_map["$token"]=1
    done < "$SUCCESS_FILE"
  fi

  if [ -f "$FAIL_FILE" ]; then
    while read -r token; do
      fail_map["$token"]=1
    done < "$FAIL_FILE"
  fi

  new_tokens=()
  for ((i=0; i<TOKEN_COUNT; i++)); do
    while : ; do
      token=$(generate_token)
      if [[ -z "${token_map[$token]}" ]]; then
        token_map["$token"]=1
        if write_with_retry "$TOKEN_FILE" "$token"; then
          new_tokens+=("$token")
        else
          echo "写入token $token 失败" | tee -a "$LOG_FILE"
        fi
        break
      fi
    done
  done

  process_token() {
    token=$1
    success_map=$2
    fail_map=$3
    LOG_FILE=$4

    if [[ -n "${success_map[$token]}" ]] || [[ -n "${fail_map[$token]}" ]]; then
      return
    fi

    url="https://dy.tagsub.net/api/v1/client/subscribe?token=$token"
    response=$(curl -s -o /dev/null -w "%{http_code}" -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" "$url" --retry 5 --retry-delay 2)
    if [ "$response" -eq 200 ]; then
      if write_with_retry "$SUCCESS_FILE" "$token"; then
        success_map["$token"]=1
      else
        echo "写入成功文件失败" | tee -a "$LOG_FILE"
      fi
    else
      if write_with_retry "$FAIL_FILE" "$token"; then
        fail_map["$token"]=1
      else
        echo "写入失败文件失败" | tee -a "$LOG_FILE"
      fi
    fi
  }

  export -f process_token
  export -f write_with_retry
  export BASE_DIR TOKEN_FILE SUCCESS_FILE FAIL_FILE LOG_FILE
  export MAX_RETRIES RETRY_DELAY

  for token in "${new_tokens[@]}"; do
    process_token "$token" success_map fail_map "$LOG_FILE"
  done

  successful_tokens=$(cat "$SUCCESS_FILE")
  message="拉取成功的token完整链接：\n"
  for token in $successful_tokens; do
    link="https://dy.tagsub.net/api/v1/client/subscribe?token=$token"
    message+="$link\n"
  done

  TELEGRAM_API_URL="https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage"

  send_telegram_message() {
    local message=$1
    curl -s -X POST "$TELEGRAM_API_URL" -d chat_id="$CHAT_ID" -d text="$message"
  }

  send_telegram_message "$message"
}

for ((i=1; i<=LOOP_COUNT; i++)); do
  run_script
done
