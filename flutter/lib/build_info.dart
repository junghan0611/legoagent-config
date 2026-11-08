/// 빌드 스크립트가 실제 빌드 시 주입하는 값. 지정하지 않은 개발 빌드도 명확히 표시한다.
const _version = String.fromEnvironment('APP_VERSION');
const _buildTime = String.fromEnvironment('BUILD_TIME');
const appVersion = _version == '' ? '개발 빌드' : _version;
const buildTime = _buildTime == '' ? '빌드 시각 미기록' : _buildTime;

/// 새 릴리스는 위에 추가하고 이전 항목은 보존한다.
const changelog = <({String date, String version, String changes})>[
  (date: '2026-11-08', version: '1.1.1+3', changes: '실제 포트 정정, 피아노 검은건반 추가'),
  (
    date: '2026-11-08',
    version: '1.1.0+2',
    changes: '5탭 한판, 피아노, 글자, A 모터, 설정/변경 이력',
  ),
  (date: '2026-11-03', version: '기존 리모컨', changes: '운전, 승강기, A 모터 조작'),
];
