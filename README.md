# 시작 안내 자동 닫기 (Startup Notice Dismiss, HMG-API 모드)

헤드유닛이 부팅되거나 슬립(QuickBoot)에서 깨어날 때, 또는 헤드유닛이 켜진 채로 다시 시동(READY)을
걸 때 나오는 **시작 안내(동의) 화면**을 자동으로 닫는 HMG-API 모드입니다.

실제로 화면을 닫는 일은 HMG-API의 `startup_notice` 명령이 합니다(내부적으로
`IMicomFactoryService.hideConsentScreen()`, 즉 `com.hkmc.factory` 82번 호출). 이 모드는
**언제 보낼지만** 정하고, 안전장치는 HMG-API가 그대로 적용합니다.

- 차주가 HMG-API 앱에서 허용 스위치를 켠 경우에만 동작
- 기어가 **P**일 때만 동작
- **시동당 한 번**만 동작

> **주의:** 시작 안내는 제조사가 운전자에게 확인받도록 만든 안전·법적 고지입니다. 이 모드는
> 그 확인을 건너뜁니다. 사용 여부는 차주가 판단해 주세요. 되돌리는 호출(역동작)은 알려져 있지 않습니다.

## 대상 차량

- 현대 쏘나타 하이브리드(DN8 HEV) 국내형, 펌웨어 260902 (`DN823HEV.KOR`), HMG-API 1.0.2
  : HMG-API 차량 리포트에서 `hideConsentScreen`이 매핑된 것을 확인했습니다. **실차 동작은 아직 검증 전**입니다.
- HMG-API가 `startup_notice`를 지원하는 다른 차량에서도 동작할 수 있지만, NEMESIS 패키지의
  호환 차종은 위 차량으로만 적어 두었습니다(`build.py`).

## 설치 전 준비

1. **HMG-API 1.0.0 이상**이 설치돼 있어야 합니다.
2. HMG-API 앱의 **Settings**에서 **Startup notice → Allow mods to dismiss it**을 켭니다(기본 꺼짐).
3. 모드가 처음 명령을 보낼 때 HMG-API가 화면에서 허용 여부를 묻습니다. **허용**을 눌러 주세요.
   질문이 떠 있는 동안 모드는 1분까지 다시 시도합니다.
4. **같은 일을 하는 다른 것은 함께 쓰지 마세요.** NEMESIS 패키지 *HKMC Factory 82*
   (`local.hkmc.factory82`)는 HMG-API를 거치지 않고 같은 호출을 직접 보내므로 삭제를 권합니다.
   카탈로그 모드 *Comfort & Startup*도 같은 기능이 있습니다(함께 써도 HMG-API가 시동당 한 번만 허용하므로 해는 없습니다).

### HMG-API 1.0.x 사용 시 알아둘 점

HMG-API **1.0.x**는 "시동당 한 번" 기록을 QuickBoot로 슬립했다 깨어날 때 초기화하지 않습니다.
그래서 헤드유닛이 완전히 재부팅되기 전까지는 **두 번째 주행부터 `once per start`로 거절**되어
닫히지 않을 수 있습니다. 이 문제는 HMG-API **1.1.0-rc.4**에서 고쳐졌으니(새 주행마다 초기화,
P단에서 몇 번 더 다시 닫기), 가능하면 HMG-API 1.1.0 이상으로 올려 주세요.

## 설치

### HMG-API 앱으로 설치

1. `startup-notice-dismiss-v1.1.1-hmgapi-usb.zip`을 FAT32 USB 메모리 최상위에 압축 해제합니다.
   `HMGAPI/updates/startup-notice-dismiss-v1.1.1.zip`이 생기면 됩니다.
2. 차량에 꽂고 HMG-API 앱의 업데이트 화면에서 모드를 설치한 뒤 **Apply changes**를 누릅니다.

USB 디버깅(ADB over USB)이 켜져 있으면 USB 메모리를 읽지 못하므로 꺼 두세요.

### NEMESIS로 설치

`startup-notice-dismiss-v1.1.1-nemesis-usb.zip`을 FAT32/exFAT USB 메모리 최상위에 압축 해제하고,
Android가 다 켜진 뒤 꽂아서 설치를 확인합니다.

## 설정 (HMG-API 앱)

| 설정 | 기본값 |
|---|---|
| 시작 안내 자동으로 닫기 | 켬 |
| 시동(READY)을 걸 때도 닫기 | 켬 |
| 부팅 후 기다릴 시간 (초, 0~10) | 5 |
| 깨어나거나 시동 건 뒤 기다릴 시간 (초, 0~10) | 2 |

안내 화면이 늦게 떠서 닫히지 않으면 기다릴 시간을 늘려 주세요. 닫기는 **안내 화면이 실제로 뜬 뒤에**
보내야 합니다. 너무 일찍 보내면 HMG-API는 `ok`라고 답하지만 화면은 그 뒤에 뜨고, HMG-API 1.0.x는 한 시동에 한 번만
보내기 때문에 다시 닫지 못합니다. 설정은 다음 부팅이나 깨어남부터 적용됩니다.

## 동작 방식

- **부팅:** 서비스가 부팅 후 3분 안에 시작되면 부팅으로 봅니다. `sys.boot_completed=1`을
  기다린 뒤(최대 2분, 끝내 안 오면 그대로 진행) 설정한 시간만큼 더 기다렸다가 닫습니다.
- **깨어남:** 1초마다 `/proc/uptime`을 확인합니다. 한 번에 20초 넘게 뛰면 슬립에서 깨어난
  것으로 보고, 설정한 시간만큼 기다렸다가 닫습니다.
- **시동(READY):** 헤드유닛이 슬립하지 않은 채 시동을 껐다 다시 켜면 uptime이 뛰지 않습니다.
  그래서 3초마다 `hv.ready`를 읽어, 0(꺼짐)을 본 뒤 1(READY)이 되면 새 시동으로 보고 닫습니다.
  차량이 `hv.ready`를 알려주지 않으면(`-`) 이 감지만 건너뜁니다. 설정에서 끌 수 있습니다.
  같은 시동에 부팅·깨어남과 겹쳐 보내도 HMG-API가 `once per start`로 한 번만 처리합니다.
- **재시도:** 1초 간격으로 부팅 때 최대 60번, 깨어나거나 시동 걸 때 최대 40번 보냅니다. HMG-API 응답에 따라 이렇게 처리합니다.

  | 응답 | 처리 |
  |---|---|
  | `ok ...` | 닫힘, 끝 |
  | `refused: once per start` | 이번 시동에서 이미 닫힘, 끝 |
  | `refused: the car's service failed (...)` | HMG-API가 차량의 닫기 기능 호출에 실패. 이유를 로그에 남기고 끝 (1.0.x는 이번 시동에 다시 보낼 수 없음) |
  | `refused: the owner hasn't allowed it` | 앱의 허용 스위치가 꺼져 있음, 로그에 안내하고 끝 |
  | `refused: the owner didn't allow ...` | 차주가 거부함, 끝 |
  | `refused: unknown command ...` | HMG-API가 너무 오래됨, 끝 |
  | `refused: waiting for the owner ...` | 허용 질문이 떠 있음, 다시 시도 |
  | `refused: the car isn't in P` | 부팅 직후 기어 값이 늦게 오는 경우라 다시 시도. 차량의 `gear.park` 값을 로그에 함께 남김 |
  | `the vehicle service isn't running (yet)` | HMG-API 차량 서비스가 아직 시작 전. 시도 횟수를 쓰지 않고 최대 3분 기다림 |
  | 응답 없음 | 다시 시도 |

- 부팅한 지 3분이 지나 서비스가 시작되면(모드 설치, 서비스 재시작) 이미 운전 중일 수 있으므로 닫지 않습니다.
  `/proc/uptime`을 읽지 못하는 경우에도 판단을 미루고 닫지 않습니다.
- Android 4.4 헤드유닛의 `sleep`은 정수 초만 받기 때문에 소수 초를 쓰지 않습니다.

## 확인과 시험 (차량에서)

로그는 `/data/hmgapi/logs/startup-notice-dismiss/notice.log`에 남습니다.

```sh
sh notice.sh check     # 설정과 현재 상태(uptime, boot_completed, 기어 P, hv.ready)만 출력. hv.ready가 0/1로 나오는지 확인
sh notice.sh dismiss   # 지금 한 번 닫기를 보내고 HMG-API 응답을 출력 (P단에서 시험)
```

## 빌드

[HMG-API](https://github.com/VysseCodes/HMG-API) 소스 체크아웃과 openssl, zip, unzip이 필요합니다.

```bash
./build.py keygen ~/.hmgapi/author.key      # 처음 한 번: 본인 서명 키 생성
./build.py ~/.hmgapi/author.key ../HMG-API
```

`dist/` 바로 아래에는 **GitHub 릴리즈에 올리는 파일만** 만들어집니다.

- `<id>-v<버전>-hmgapi-usb.zip`: HMG-API 앱으로 설치 (USB 최상위에 압축 해제)
- `<id>-v<버전>-nemesis-usb.zip`: NEMESIS로 설치 (USB 최상위에 압축 해제)
- `SHA256SUMS`: 위 두 파일의 체크섬

릴리즈에 올리지 않는 중간 산출물은 `dist/extra/`에 따로 둡니다. 서명된 모드 본체(`.hmgapi.zip`,
위 두 파일 안에 이미 들어 있음)와 NEMESIS 패키지 스토어 등록용 파일(`-nemesis-package.zip`)입니다.
업데이트는 처음 설치한 모드와 같은 키로 서명해야 합니다.

릴리즈 올리기 (PowerShell, `gh` 로그인 후):

```powershell
gh release create v<버전> --target main --notes-file dist/RELEASE_NOTES.md (Get-ChildItem dist/*.zip).FullName dist/SHA256SUMS
```

## 테스트

```bash
test/run.sh                  # bash
TEST_SHELL=mksh test/run.sh  # 헤드유닛과 같은 mksh
```

가짜 `hmgapid`, `getprop`, `sleep`(실제로 기다리지 않고 가짜 uptime을 올림)으로 부팅, 깨어남,
시동(READY) 감지, HMG-API 응답별 처리, 차량 서비스 대기, uptime 읽기 실패, `check`/`dismiss` 명령을 시험합니다.

## 라이선스

AGPL-3.0. [LICENSE](LICENSE)를 참고하세요. `build.py`는
[dibble9012/auto-heat-and-cool-seats](https://github.com/dibble9012/auto-heat-and-cool-seats)의
빌드 스크립트(AGPL-3.0)를 가져와 고쳐 쓴 것입니다.
