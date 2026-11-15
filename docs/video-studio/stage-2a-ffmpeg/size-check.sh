# Сверка размера хранилища с маркером. POSIX sh.
#
# Один модуль на две стороны проверки: guard.sh внутри образа и
# scripts/verify-storage.sh на хосте. Дублирование кода раньше дало расхождение
# — ограда перешла на абсолютный допуск, а проверка на хосте осталась на
# процентном.
#
# Допуск 1 GiB абсолютный, а не проценты: маркер пишется из того же df, поэтому
# расхождение означает подмену каталога, а не округление. На объёме 927 GiB
# допуск 5% составлял 46 GiB и пропускал корневой раздел 935 GiB.
#
# Использование:
#   . ./size-check.sh
#   size_matches "$total_ki" "$declared_gib" || die "размер не совпадает"

SIZE_TOLERANCE_KI=1048576

size_matches() {
  _sm_total="${1:-0}"
  _sm_declared="${2:-}"
  case "$_sm_total" in ''|*[!0-9]*) return 1 ;; esac
  case "$_sm_declared" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_sm_total" -gt 0 ] || return 1
  [ "$_sm_declared" -gt 0 ] || return 1
  _sm_expected=$(( _sm_declared * 1048576 ))
  _sm_diff=$(( _sm_total - _sm_expected ))
  [ "$_sm_diff" -lt 0 ] && _sm_diff=$(( -_sm_diff ))
  [ "$_sm_diff" -le "$SIZE_TOLERANCE_KI" ]
}
