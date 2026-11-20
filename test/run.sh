#!/bin/bash
# 차 없이 mod/notice.sh 를 돌리는 시나리오 테스트. 가짜 hmgapid, getprop, sleep을 씁니다.
#   test/run.sh                 bash로 실행
#   TEST_SHELL=mksh test/run.sh 헤드유닛과 같은 mksh로 실행
#
# 가짜 sleep은 실제로 기다리지 않고 가짜 uptime을 인자만큼 올립니다. events 파일의
# "<uptime> <동작>" 줄은 그 시각이 되면 실행되고("jump <초>"는 그만큼 슬립한 것으로 처리),
# uptime이 end 에 닿으면 스크립트를 끝냅니다.
HERE=$(cd "$(dirname "$0")/.." && pwd)
TEST_SHELL=${TEST_SHELL:-bash}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export T PATH="$T/bin:$PATH" HMGAPI_MOD=startup-notice-dismiss UP="$T/uptime" GETPROP="$T/bin/getprop"
mkdir "$T/bin"

cat > "$T/bin/hmgapid" <<'EOF'
#!/bin/bash
case "$1" in
setting-get) cat "$T/settings" ;;
vehicle) shift; for n in "$@"; do echo "$n $(cat "$T/r/$n" 2>/dev/null || echo -)"; done ;;
vehicle-do)
    shift
    read -r up rest < "$UP"
    echo "${up%.*} $*" >> "$T/sent"
    if [ -s "$T/answers" ]; then           # 미리 정한 응답을 한 줄씩, 다 쓰면 기본 응답
        IFS= read -r answer < "$T/answers"
        tail -n +2 "$T/answers" > "$T/answers2"; mv "$T/answers2" "$T/answers"
        echo "$answer"
    else
        cat "$T/default_answer"
    fi ;;
esac
EOF

cat > "$T/bin/getprop" <<'EOF'
#!/bin/bash
[ "$1" = sys.boot_completed ] && cat "$T/boot_completed"
EOF

cat > "$T/bin/sleep" <<'EOF'
#!/bin/bash
read -r up rest < "$UP"; up=${up%.*}
up=$(( up + ${1%.*} ))
while [ -s "$T/events" ]; do
    read -r at action < "$T/events"
    [ "$at" -le "$up" ] || break
    tail -n +2 "$T/events" > "$T/events2"; mv "$T/events2" "$T/events"
    case "$action" in
    "jump "*) up=$(( up + ${action#jump } )) ;;
    *) eval "$action" ;;
    esac
done
echo "$up.00 0" > "$UP"
[ "$up" -ge "$(cat "$T/end")" ] && kill "$PPID"
exit 0
EOF
chmod +x "$T"/bin/*

OK_ANSWER="ok startup notice dismissed"
NOT_ALLOWED="refused: the owner hasn't allowed it (HMG-API settings: startup notice)"
ASKING="refused: waiting for the owner to allow startup_notice for startup-notice-dismiss (a question is on the screen)"
NOT_PARK="refused: the car isn't in P"
ONCE="refused: once per start"

pass=0; fail=0
result() {    # result <이름> <조건 결과 0/1> <설명>
    if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "ok   $1"
    else fail=$((fail + 1)); echo "FAIL $1: $3"; sed 's/^/     | /' "$T/log"; echo "     sent:"; sed 's/^/     | /' "$T/sent" 2>/dev/null; fi
}

# run <설정 JSON> <시작 uptime> <끝 uptime> [준비 명령...]: 서비스를 돌림
run() {
    local settings=$1 start=$2 end=$3; shift 3
    rm -rf "$T/r" "$T/sent" "$T/answers" "$T/events"; mkdir "$T/r"
    echo "$settings" > "$T/settings"; echo "$start.00 0" > "$UP"; echo "$end" > "$T/end"
    echo 1 > "$T/boot_completed"; echo "$OK_ANSWER" > "$T/default_answer"
    echo 1 > "$T/r/gear.park"; echo 1 > "$T/r/hv.ready"
    for c in "$@"; do eval "$c"; done
    $TEST_SHELL "$HERE/mod/notice.sh" > "$T/log" 2>&1 &
    wait $! 2>/dev/null
}

sent_count() { [ -f "$T/sent" ] && wc -l < "$T/sent" | tr -d ' ' || echo 0; }
first_sent_uptime() { [ -f "$T/sent" ] && head -1 "$T/sent" | cut -d' ' -f1 || echo -; }
nth_sent_uptime() { sed -n "${1}p" "$T/sent" | cut -d' ' -f1; }
logged() { grep -q -- "$1" "$T/log"; }

# --- 부팅
run '{}' 30 60
result "부팅: 한 번 닫음" $([ "$(sent_count)" = 1 ] && logged "시작 안내를 닫음" && echo 0 || echo 1) "1회 전송, 닫음 로그"
result "부팅: 기본 2초 뒤" $([ "$(first_sent_uptime)" = 32 ] && echo 0 || echo 1) "uptime 32에 전송"

run '{}' 30 100 'echo 0 > $T/boot_completed' 'echo "45 echo 1 > $T/boot_completed" > $T/events'
result "부팅: sys.boot_completed 기다림" $([ "$(sent_count)" = 1 ] && [ "$(first_sent_uptime)" -ge 47 ] && echo 0 || echo 1) "45초에 부팅 완료 + 2초"

run '{}' 30 200 'echo 0 > $T/boot_completed'
result "부팅: boot_completed가 끝내 안 와도 진행" $([ "$(sent_count)" = 1 ] && [ "$(first_sent_uptime)" -ge 150 ] && logged "확인되지 않아" && echo 0 || echo 1) "120초 대기 후 전송"

run '{"boot_delay":5}' 30 60
result "부팅: boot_delay 설정" $([ "$(first_sent_uptime)" = 35 ] && echo 0 || echo 1) "uptime 35에 전송"

run '{"boot_delay":99}' 30 60
result "부팅: 지연은 최대 10초" $([ "$(first_sent_uptime)" = 40 ] && echo 0 || echo 1) "uptime 40에 전송"

run '{"boot_delay":"abc"}' 30 60
result "부팅: 잘못된 지연값은 기본값" $([ "$(first_sent_uptime)" = 32 ] && echo 0 || echo 1) "uptime 32에 전송"

run '{}' 500 530
result "늦게 시작된 서비스(재시작·설치): 닫지 않음" $([ "$(sent_count)" = 0 ] && logged "닫지 않음" && echo 0 || echo 1) "전송 없음"

run '{"enabled":false}' 30 700 'echo "60 jump 600" > $T/events'
result "설정 꺼짐: 부팅·깨어남 모두 안 보냄" $([ "$(sent_count)" = 0 ] && echo 0 || echo 1) "전송 없음"

# --- HMG-API 응답별 처리
run '{}' 30 80 'echo "$NOT_ALLOWED" > $T/default_answer'
result "허용 스위치 꺼짐: 1번만 보내고 안내" $([ "$(sent_count)" = 1 ] && logged "Startup notice" && echo 0 || echo 1) "1회, 안내 로그"

run '{}' 30 80 'printf "%s\n%s\n" "$ASKING" "$ASKING" > $T/answers'
result "허용 질문이 떠 있음: 다시 시도 후 닫음" $([ "$(sent_count)" = 3 ] && logged "시작 안내를 닫음" && echo 0 || echo 1) "3회"

run '{}' 30 80 'printf "%s\n%s\n%s\n" "$NOT_PARK" "$NOT_PARK" "$NOT_PARK" > $T/answers'
result "아직 P 아님: 다시 시도 후 닫음" $([ "$(sent_count)" = 4 ] && [ "$(grep -c "P가 아니라고" $T/log)" = 1 ] && echo 0 || echo 1) "4회, 같은 응답은 로그 1번"

run '{}' 30 200 'echo "$NOT_PARK" > $T/default_answer'
result "끝내 P가 아님: 60번에서 멈춤" $([ "$(sent_count)" = 60 ] && logged "60번 시도했지만" && echo 0 || echo 1) "60회"

run '{}' 30 80 'echo "$ONCE" > $T/default_answer'
result "이미 닫힘(once per start): 다시 안 보냄" $([ "$(sent_count)" = 1 ] && echo 0 || echo 1) "1회"

run '{}' 30 80 'echo "refused: unknown command startup_notice" > $T/default_answer'
result "명령을 모르는 HMG-API: 멈춤" $([ "$(sent_count)" = 1 ] && logged "1.0.0 이상" && echo 0 || echo 1) "1회"

run '{}' 30 80 'printf "\n" > $T/answers'
result "빈 응답: 다시 시도 후 닫음" $([ "$(sent_count)" = 2 ] && echo 0 || echo 1) "2회"

# --- 슬립에서 깨어남
run '{}' 30 700 'echo "60 jump 600" > $T/events'
result "깨어남: 다시 닫음" $([ "$(sent_count)" = 2 ] && logged "깨어남" && echo 0 || echo 1) "2회"
result "깨어남: 기본 1초 뒤" $([ "$(nth_sent_uptime 2)" -ge 661 ] && [ "$(nth_sent_uptime 2)" -le 663 ] && echo 0 || echo 1) "661~663에 전송 (got $(nth_sent_uptime 2))"

run '{"wake_delay":4}' 30 700 'echo "60 jump 600" > $T/events'
result "깨어남: wake_delay 설정" $([ "$(nth_sent_uptime 2)" -ge 664 ] && [ "$(nth_sent_uptime 2)" -le 666 ] && echo 0 || echo 1) "664~666에 전송 (got $(nth_sent_uptime 2))"

run '{}' 30 120 'echo "60 jump 10" > $T/events'
result "짧은 지연(20초 이하)은 깨어남이 아님" $([ "$(sent_count)" = 1 ] && echo 0 || echo 1) "1회"

run '{}' 500 1200 'printf "%s\n%s\n" "600 jump 300" "1000 jump 100" > $T/events'
result "늦게 시작된 뒤에도 깨어날 때마다 닫음" $([ "$(sent_count)" = 2 ] && echo 0 || echo 1) "2회"

run '{}' 30 900 'echo "$NOT_PARK" > $T/default_answer' 'echo "150 jump 600" > $T/events'
result "깨어남: P가 아니면 40번에서 멈춤" $([ "$(sent_count)" = 100 ] && echo 0 || echo 1) "부팅 60 + 깨어남 40 = 100회 (got $(sent_count))"

# --- 슬립 없이 다시 시동 (hv.ready 0 → 1)
run '{}' 30 200 'printf "%s\n%s\n" "100 echo 0 > $T/r/hv.ready" "130 echo 1 > $T/r/hv.ready" > $T/events'
result "시동(READY): 슬립 없이 다시 시동하면 닫음" $([ "$(sent_count)" = 2 ] && logged "시동(READY): 시작 안내를 닫음" && echo 0 || echo 1) "부팅 1 + 시동 1 = 2회"
result "시동(READY): 3초 확인 + 1초 대기 안에 보냄" $([ "$(nth_sent_uptime 2)" -ge 131 ] && [ "$(nth_sent_uptime 2)" -le 135 ] && echo 0 || echo 1) "131~135에 전송 (got $(nth_sent_uptime 2))"

run '{}' 30 200
result "시동(READY): 계속 READY면 부팅 때만" $([ "$(sent_count)" = 1 ] && echo 0 || echo 1) "1회"

run '{}' 30 200 'rm $T/r/hv.ready' 'echo "130 echo 1 > $T/r/hv.ready" > $T/events'
result "시동(READY): hv.ready를 모르면(-) 판단 안 함" $([ "$(sent_count)" = 1 ] && echo 0 || echo 1) "1회"

run '{"ready_trigger":false}' 30 200 'printf "%s\n%s\n" "100 echo 0 > $T/r/hv.ready" "130 echo 1 > $T/r/hv.ready" > $T/events'
result "시동(READY): 설정에서 끄면 안 보냄" $([ "$(sent_count)" = 1 ] && logged "설정이 꺼져 있어" && echo 0 || echo 1) "1회"

run '{}' 30 200 'echo 0 > $T/r/hv.ready' 'echo "$ONCE" > $T/default_answer' 'echo "$OK_ANSWER" > $T/answers' 'echo "100 echo 1 > $T/r/hv.ready" > $T/events'
result "시동(READY): ACC로 부팅 뒤 READY는 once per start로 끝" $([ "$(sent_count)" = 2 ] && logged "이미 닫았다고" && echo 0 || echo 1) "2회"

run '{}' 30 300 'printf "%s\n%s\n%s\n%s\n" "100 echo 0 > $T/r/hv.ready" "130 echo 1 > $T/r/hv.ready" "160 echo 0 > $T/r/hv.ready" "190 echo 1 > $T/r/hv.ready" > $T/events'
result "시동(READY): 시동마다 한 번씩" $([ "$(sent_count)" = 3 ] && echo 0 || echo 1) "부팅 1 + 시동 2 = 3회"

run '{}' 30 900 'printf "%s\n%s\n" "100 echo 0 > $T/r/hv.ready" "120 jump 600" > $T/events' 'echo "125 echo 1 > $T/r/hv.ready" >> $T/events'
result "깨어남과 READY가 겹치면 깨어남으로 한 번만" $([ "$(sent_count)" = 2 ] && echo 0 || echo 1) "부팅 1 + 깨어남 1 = 2회 (got $(sent_count))"

# --- HMG-API 차량 서비스가 늦게 뜸
run '{}' 30 300 'for i in $(seq 70); do echo "the vehicle service isn'"'"'t running (yet)"; done > $T/answers'
result "차량 서비스가 70초 늦게 떠도 닫음 (시도 횟수와 별도)" $([ "$(sent_count)" = 71 ] && logged "시작 안내를 닫음" && [ "$(grep -c "아직 시작되지 않음" $T/log)" = 1 ] && echo 0 || echo 1) "71회 (got $(sent_count))"

run '{}' 30 400 'echo "the vehicle service isn'"'"'t running (yet)" > $T/default_answer'
result "차량 서비스가 끝내 안 뜨면 3분 뒤 포기" $([ "$(sent_count)" = 181 ] && logged "180초 동안 시작되지 않아" && echo 0 || echo 1) "181회 (got $(sent_count))"

# --- uptime을 읽지 못함
run '{}' 30 60 ': > $UP'
result "uptime을 못 읽으면 부팅 닫기 안 함, 멈추지 않음" $([ "$(sent_count)" = 0 ] && logged "읽지 못해" && ! grep -qi "syntax\|error\|오류" $T/log && echo 0 || echo 1) "전송 없음, 오류 없음"

# --- check / dismiss 명령
run '{"boot_delay":3}' 30 31
out=$($TEST_SHELL "$HERE/mod/notice.sh" check 2>&1)
echo "$out" > "$T/log"
result "check: 설정·상태 출력, 전송 없음" $(echo "$out" | grep -q "부팅 후 3초" && echo "$out" | grep -q "시동 걸 때도 닫기 켜짐" && echo "$out" | grep -q "기어 P 1" && [ ! -s "$T/sent" ] && echo 0 || echo 1) "출력 확인"

rm -f "$T/sent"; echo "$NOT_ALLOWED" > "$T/default_answer"
out=$($TEST_SHELL "$HERE/mod/notice.sh" dismiss 2>&1)
echo "$out" > "$T/log"
result "dismiss: 한 번 보내고 응답 출력" $(echo "$out" | grep -q "응답: refused: the owner hasn't allowed" && [ "$(sent_count)" = 1 ] && echo 0 || echo 1) "1회, 응답 출력"

echo "$pass passed, $fail failed ($TEST_SHELL)"
[ $fail = 0 ]
