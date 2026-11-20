#!/system/bin/sh
# 시작 안내 자동 닫기 (Startup Notice Dismiss)
#
# 헤드유닛이 부팅되거나 슬립(QuickBoot)에서 깨어날 때 나오는 시작 안내(동의) 화면을
# HMG-API의 startup_notice 명령(hmgapid vehicle-do startup_notice dismiss)으로 닫습니다.
# 실제 호출(IMicomFactoryService.hideConsentScreen, com.hkmc.factory 82)과 안전장치
# (차주 허용 스위치, 기어 P, 시동당 1회)는 HMG-API가 맡고, 이 스크립트는 "언제 보낼지"만 정합니다.
#
# 시작 안내가 뜨는 때:
#   - 부팅:  서비스가 부팅 직후(uptime < BOOT_WINDOW_SECONDS)에 시작됨
#            → sys.boot_completed=1 을 기다린 뒤 boot_delay 초 후에 닫기
#   - 깨어남: /proc/uptime 이 한 번에 WAKE_GAP_SECONDS 넘게 뜀(슬립 시간이 더해짐)
#            → wake_delay 초 후에 닫기
#   - 시동:  헤드유닛이 슬립하지 않은 채 다시 시동을 걸 때. hv.ready 가 0이었다가 1이 됨
#            (READY_POLL_SECONDS마다 확인) → wake_delay 초 후에 닫기. 설정 ready_trigger로 끌 수 있음
#   부팅한 지 오래된 뒤 서비스가 다시 시작되면(모드 설치·재시작) 부팅으로 보지 않습니다.
#   같은 시동에 여러 번 보내도 HMG-API가 "once per start"로 한 번만 처리합니다.
#
# 사용법: notice.sh          모드 서비스로 실행
#         notice.sh check    설정과 현재 상태만 출력, 명령은 보내지 않음
#         notice.sh dismiss  지금 한 번 닫기를 보내고 응답을 출력 (차에서 시험용)
#
# mksh 전용. Android 4.4의 sleep은 정수 초만 받으므로 소수 초를 쓰지 않습니다.

MOD=startup-notice-dismiss
UP=${UP:-/proc/uptime}
GETPROP=${GETPROP:-getprop}

# 설정을 한 번도 저장하지 않았을 때 쓰는 기본값 (settings.json의 default와 맞춰 둘 것)
DEFAULT_ENABLED=true
DEFAULT_BOOT_DELAY_SECONDS=2
DEFAULT_WAKE_DELAY_SECONDS=1
DEFAULT_READY_TRIGGER=true
MAX_DELAY_SECONDS=10

BOOT_WINDOW_SECONDS=180         # 서비스가 부팅 후 이 시간 안에 시작돼야 "부팅"으로 봄
BOOT_READY_WAIT_SECONDS=120     # sys.boot_completed=1 을 기다리는 최대 시간
WAKE_GAP_SECONDS=20             # 폴링 사이에 uptime이 이보다 많이 뛰면 "깨어남"
POLL_SECONDS=1                  # 깨어남 감지 주기
RETRY_SECONDS=1                 # 닫기 재시도 간격
MAX_ATTEMPTS_BOOT=60            # 부팅 때 최대 시도 횟수 (약 1분)
MAX_ATTEMPTS_WAKE=40            # 깨어날 때·시동 때 최대 시도 횟수
READY_POLL_SECONDS=3            # hv.ready 확인 주기 (hmgapid 작업 슬롯을 잠깐 쓰므로 너무 자주 하지 않음)
VEHICLE_SERVICE_WAIT_SECONDS=180  # HMG-API 차량 서비스가 늦게 뜰 때 시도 횟수와 따로 기다리는 최대 시간

log() { echo "$(date '+%m-%d %H:%M:%S') $*"; }

uptime_s() {  # 부팅 후 지난 초(정수). 읽지 못하면 -1
    local up rest
    read up rest < "$UP" 2>/dev/null
    up=${up%.*}
    case "$up" in ''|*[!0-9]*) echo -1 ;; *) echo "$up" ;; esac
}

load_settings() {
    if [ -n "$HMGAPI_MOD" ]; then S=$(hmgapid setting-get); else S=$(hmgapid setting-get $MOD); fi
}

setting() {   # setting <키> <기본값>: 설정 JSON({"enabled":false,"boot_delay":3})에서 값 하나
    local v
    v=${S#*\"$1\":}
    [ "$v" = "$S" ] && { echo "$2"; return; }
    v=${v# }; v=${v#\"}; v=${v%%[\",\}]*}
    echo "${v:-$2}"
}

seconds_setting() {  # seconds_setting <키> <기본값>: 0~MAX_DELAY_SECONDS 사이의 정수 초
    local seconds
    seconds=$(setting $1 $2)
    seconds=${seconds%%.*}
    case "$seconds" in ''|*[!0-9]*) seconds=$2 ;; esac
    [ $seconds -gt $MAX_DELAY_SECONDS ] && seconds=$MAX_DELAY_SECONDS
    echo $seconds
}

enabled() { [ "$(setting enabled $DEFAULT_ENABLED)" != false ]; }

ready_trigger_enabled() { [ "$(setting ready_trigger $DEFAULT_READY_TRIGGER)" != false ]; }

boot_completed() { [ "$($GETPROP sys.boot_completed 2>/dev/null)" = 1 ]; }

wait_for_boot_completed() {  # sys.boot_completed=1 을 기다림, 끝내 안 되면 그냥 진행 (HMG-API가 P단을 확인함)
    local waited=0
    while ! boot_completed; do
        if [ $waited -ge $BOOT_READY_WAIT_SECONDS ]; then
            log "sys.boot_completed 를 ${waited}초 기다렸지만 확인되지 않아 그대로 진행"
            return
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    [ $waited -gt 0 ] && log "sys.boot_completed=1 확인 (${waited}초 대기)"
}

snapshot() {  # snapshot <이름>...: SNAP에 이름=값 목록으로 저장
    # hmgapid vehicle 은 답을 바로 주고도 3초간 연결을 붙잡으므로, 백그라운드로 한 번만 부르고 필요한 줄만 읽음
    local n=$#
    SNAP=$({ hmgapid vehicle "$@" 2>/dev/null & } | {
        while [ $n -gt 0 ] && read a b; do echo "$a=$b"; n=$(( n - 1 )); done
    })
}

seen() {      # seen <이름>: SNAP에 있는 값, 없으면 -
    local w
    for w in $SNAP; do
        if [ "${w%%=*}" = "$1" ] && [ -n "${w#*=}" ]; then echo "${w#*=}"; return; fi
    done
    echo -
}

send_dismiss() { hmgapid vehicle-do startup_notice dismiss 2>&1; }

dismiss_with_retry() {  # dismiss_with_retry <계기> <최대 시도 횟수>: 닫히거나 더 할 수 없을 때까지 재시도
    local trigger=$1 max_attempts=$2 attempt=1 service_waited=0 answer last_answer=
    while [ $attempt -le $max_attempts ]; do
        answer=$(send_dismiss)
        case "$answer" in
        *"isn't running"*)
            # HMG-API 차량 서비스가 아직 시작 전: 시도 횟수를 쓰지 않고 시간 기준으로 기다림
            if [ $service_waited -ge $VEHICLE_SERVICE_WAIT_SECONDS ]; then
                log "$trigger: HMG-API 차량 서비스가 ${service_waited}초 동안 시작되지 않아 포기함"
                return 1
            fi
            [ $service_waited = 0 ] && log "$trigger: HMG-API 차량 서비스가 아직 시작되지 않음, 기다리는 중"
            service_waited=$(( service_waited + RETRY_SECONDS ))
            sleep $RETRY_SECONDS
            continue ;;
        esac
        case "$answer" in
        ok*)
            log "$trigger: 시작 안내를 닫음 (${attempt}번째 시도)"
            return 0 ;;
        *"once per start"*)
            log "$trigger: HMG-API가 이번 시동에서 이미 닫았다고 답함 (HMG-API 1.0.x는 QuickBoot 뒤 다음 주행에도 이렇게 답할 수 있음)"
            return 0 ;;
        *"hasn't allowed"*)
            log "$trigger: HMG-API 앱 설정에서 'Startup notice' 허용이 꺼져 있음. 켜야 동작합니다"
            return 1 ;;
        *"didn't allow"*)
            log "$trigger: 차주가 이 모드의 startup_notice 명령을 허용하지 않음 (HMG-API 앱: Settings, Vehicle)"
            return 1 ;;
        *"unknown command"*|*"not declared"*)
            log "$trigger: HMG-API가 startup_notice 명령을 받지 않음 ($answer). HMG-API 1.0.0 이상이 필요합니다"
            return 1 ;;
        esac
        # 다시 시도할 응답: 허용 질문이 화면에 떠 있음, 아직 P가 아님(부팅 직후 기어 값이 늦게 옴), 응답 없음
        if [ "$answer" != "$last_answer" ]; then
            case "$answer" in
            *"waiting for the owner"*) log "$trigger: HMG-API가 화면에서 허용 여부를 묻는 중, 다시 시도" ;;
            *"isn't in P"*)            log "$trigger: 기어가 P가 아니라고 함, 다시 시도" ;;
            *)                         log "$trigger: 응답을 받지 못함(${answer:-빈 응답}), 다시 시도" ;;
            esac
            last_answer=$answer
        fi
        attempt=$(( attempt + 1 ))
        [ $attempt -le $max_attempts ] && sleep $RETRY_SECONDS
    done
    log "$trigger: ${max_attempts}번 시도했지만 닫지 못함 (마지막 응답: ${answer:-빈 응답})"
    return 1
}

on_boot() {
    local boot_delay
    load_settings
    enabled || { log "부팅: 설정에서 꺼져 있어 동작 안 함"; return; }
    wait_for_boot_completed
    boot_delay=$(seconds_setting boot_delay $DEFAULT_BOOT_DELAY_SECONDS)
    [ $boot_delay -gt 0 ] && sleep $boot_delay
    dismiss_with_retry "부팅" $MAX_ATTEMPTS_BOOT
}

on_ready() {  # 헤드유닛이 깨어 있는 채로 다시 시동(READY)됨
    local wake_delay
    load_settings
    enabled || { log "시동(READY): 설정에서 꺼져 있어 동작 안 함"; return; }
    ready_trigger_enabled || { log "시동(READY): '시동 걸 때도 닫기' 설정이 꺼져 있어 동작 안 함"; return; }
    wake_delay=$(seconds_setting wake_delay $DEFAULT_WAKE_DELAY_SECONDS)
    [ $wake_delay -gt 0 ] && sleep $wake_delay
    dismiss_with_retry "시동(READY)" $MAX_ATTEMPTS_WAKE
}

check_ready() {  # hv.ready 를 읽어 0이면 다음 1을 새 시동으로 표시, 그 1이 오면 on_ready
    local ready
    snapshot hv.ready
    ready=$(seen hv.ready)
    case "$ready" in
    0) ready_armed=1 ;;
    1) if [ $ready_armed = 1 ]; then
           ready_armed=0
           on_ready
       fi ;;
    esac   # - (읽지 못함)이나 다른 값은 판단하지 않음
}

on_wake() {   # on_wake <잠든 시간(초)>
    local wake_delay
    load_settings
    enabled || { log "깨어남(약 $1초 슬립): 설정에서 꺼져 있어 동작 안 함"; return; }
    wake_delay=$(seconds_setting wake_delay $DEFAULT_WAKE_DELAY_SECONDS)
    [ $wake_delay -gt 0 ] && sleep $wake_delay
    dismiss_with_retry "깨어남(약 $1초 슬립)" $MAX_ATTEMPTS_WAKE
}

case "$1" in
check)
    load_settings
    snapshot gear.park hv.ready
    echo "설정: 자동 닫기 $(enabled && echo 켜짐 || echo 꺼짐), 시동 걸 때도 닫기 $(ready_trigger_enabled && echo 켜짐 || echo 꺼짐), 부팅 후 $(seconds_setting boot_delay $DEFAULT_BOOT_DELAY_SECONDS)초, 깨어난 뒤 $(seconds_setting wake_delay $DEFAULT_WAKE_DELAY_SECONDS)초"
    echo "상태: uptime $(uptime_s)초, sys.boot_completed $($GETPROP sys.boot_completed 2>/dev/null), 기어 P $(seen gear.park), hv.ready $(seen hv.ready)"
    exit 0 ;;
dismiss)
    echo "응답: $(send_dismiss)"
    exit 0 ;;
esac

service_start_uptime=$(uptime_s)
if [ $service_start_uptime -lt 0 ]; then
    log "서비스 시작: $UP 을 읽지 못해 부팅 직후인지 알 수 없음, 이번에는 닫지 않음"
elif [ $service_start_uptime -lt $BOOT_WINDOW_SECONDS ]; then
    log "서비스 시작 (부팅 후 ${service_start_uptime}초)"
    on_boot
else
    log "서비스 시작 (부팅 후 ${service_start_uptime}초)"
    log "부팅한 지 ${BOOT_WINDOW_SECONDS}초가 지나 시작됨: 모드 설치나 서비스 재시작으로 보고 이번에는 닫지 않음"
fi

ready_armed=0                      # 시동이 꺼진 값(0)을 한 번 읽으면 1: 다음 READY를 새 시동으로 봄
last=$(uptime_s)
ready_checked_at=$last
while :; do
    sleep $POLL_SECONDS
    now=$(uptime_s)
    if [ $now -lt 0 ] || [ $last -lt 0 ]; then
        last=$now; ready_checked_at=$now   # uptime을 읽지 못한 동안은 판단하지 않음
        continue
    fi
    slept_seconds=$(( now - last ))
    if [ $slept_seconds -gt $WAKE_GAP_SECONDS ]; then
        on_wake $slept_seconds
        ready_armed=0              # 이번 시동의 안내는 처리함
        now=$(uptime_s)            # 닫기에 걸린 시간을 다음 슬립으로 착각하지 않도록
        ready_checked_at=$now
    elif [ $(( now - ready_checked_at )) -ge $READY_POLL_SECONDS ]; then
        ready_checked_at=$now
        check_ready
        now=$(uptime_s)
    fi
    last=$now
done
