#!/usr/bin/env python3
"""
OpenHands Broker — автоматические тесты.

Запуск: python3 -m pytest deployment/broker/tests/ -v
"""
import yaml
import json
import os
import subprocess
import tempfile
import pytest

TOOLS_YAML = os.path.join(os.path.dirname(__file__), "..", "tools.yaml")
WRAPPER_SH = os.path.join(os.path.dirname(__file__), "..", "broker-wrapper.sh")
JOURNAL_HELPER_SH = os.path.join(os.path.dirname(__file__), "..", "journal-logs.sh")
REPO_ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "..")


def load_yaml():
    with open(TOOLS_YAML) as f:
        return yaml.safe_load(f)


def get_tool_names():
    data = load_yaml()
    return [t["name"] for t in data.get("tools", [])]


def run_wrapper(command, broker_base=None, audit_ok=True):
    with tempfile.TemporaryDirectory() as test_dir:
        logger_dir = os.path.join(test_dir, "bin")
        os.mkdir(logger_dir)
        audit_file = os.path.join(test_dir, "audit.jsonl")
        logger_path = os.path.join(logger_dir, "logger")
        with open(logger_path, "w") as f:
            f.write("#!/usr/bin/bash\n")
            if audit_ok:
                f.write("for last; do :; done\nprintf '%s\\n' \"$last\" >> \"$MOCK_AUDIT_FILE\"\n")
            else:
                f.write("exit 1\n")
        os.chmod(logger_path, 0o755)
        env = os.environ.copy()
        env.update({
            "OPENHANDS_BROKER_BASE": broker_base or os.path.dirname(TOOLS_YAML),
            "SSH_ORIGINAL_COMMAND": command,
            "MOCK_AUDIT_FILE": audit_file,
            "PATH": logger_dir + os.pathsep + env["PATH"],
        })
        result = subprocess.run(
            ["bash", WRAPPER_SH],
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
        )
        if os.path.exists(audit_file):
            with open(audit_file) as f:
                result.audit_log = f.read()
        else:
            result.audit_log = ""
        return result


def write_registry(base, tool):
    os.mkdir(os.path.join(base, "secrets"))
    with open(os.path.join(base, "tools.yaml"), "w") as f:
        yaml.safe_dump({"tools": [tool]}, f)


# ======================================================================
# 1. Структура YAML
# ======================================================================

def test_yaml_valid():
    data = load_yaml()
    assert isinstance(data, dict)
    assert "server" in data
    assert "host" in data
    assert "user" in data
    assert "tools" in data
    assert isinstance(data["tools"], list)


def test_tool_structure():
    data = load_yaml()
    for t in data["tools"]:
        assert "name" in t, f"Tool missing name: {t}"
        assert "risk" in t, f"Tool {t['name']} missing risk"
        assert t["risk"] in ("A", "B", "C"), f"Tool {t['name']} invalid risk: {t['risk']}"
        assert "execute" in t, f"Tool {t['name']} missing execute"
        assert "verify" in t, f"Tool {t['name']} missing verify"
        assert "rollback" in t, f"Tool {t['name']} missing rollback"
        assert "secrets" in t, f"Tool {t['name']} missing secrets"
        assert isinstance(t["secrets"], list), f"Tool {t['name']} secrets not a list"
        assert "params" in t, f"Tool {t['name']} missing params"
        assert isinstance(t["params"], dict), f"Tool {t['name']} params not a dict"
        for pname, pcfg in t["params"].items():
            assert "type" in pcfg, f"Tool {t['name']} param {pname} missing type"
            assert pcfg["type"] in ("string", "integer"), f"Tool {t['name']} param {pname} invalid type"
            if pcfg.get("required") is True:
                assert "default" not in pcfg, f"Tool {t['name']} param {pname}: required + default conflict"
            if pcfg["type"] == "integer":
                assert pcfg.get("min", 0) >= 0
                if "max" in pcfg:
                    assert pcfg["max"] >= pcfg.get("min", 0)
        for secret in t["secrets"]:
            assert isinstance(secret, str), f"Tool {t['name']} secret not a string: {secret}"

# ======================================================================
# 2. Тесты ping
# ======================================================================

def test_ping_returns_pong():
    """ping должен вернуть 'pong'"""
    data = load_yaml()
    ping = [t for t in data["tools"] if t["name"] == "ping"]
    assert len(ping) == 1
    assert ping[0]["execute"] == "echo pong"


# ======================================================================
# 3. Неизвестный инструмент
# ======================================================================

def test_unknown_tool_rejected():
    """Неизвестный инструмент должен быть отклонён"""
    result = run_wrapper("nonexistent_tool_xyz")
    assert result.returncode != 0
    assert "Unknown tool" in result.stderr


# ======================================================================
# 4. Неизвестный параметр
# ======================================================================

def test_unknown_param_rejected():
    """tools.yaml не должен содержать инструментов с неописанными параметрами
    (проверка что params содержит все возможные ключи)"""
    result = run_wrapper("system_status unknown=value --dry-run")
    assert result.returncode != 0
    assert "Unknown parameter" in result.stderr


# ======================================================================
# 5. Required/default params (semantic check)
# ======================================================================

def test_params_required_default():
    """Проверка что инструменты с required params имеют их в execute"""
    data = load_yaml()
    for t in data["tools"]:
        for pname, pcfg in t.get("params", {}).items():
            if pcfg.get("required") is True:
                # Параметр должен использоваться в execute, verify или rollback
                cmd_text = f"{t.get('execute', '')} {t.get('verify', '')} {t.get('rollback', '')}"
                assert f"{{{{{pname}}}}}" in cmd_text, \
                    f"Tool {t['name']}: required param '{pname}' unused in commands"


@pytest.mark.parametrize("command", [
    "journal_logs lines=0 --dry-run",
    "journal_logs lines=501 --dry-run",
    "docker_compose_logs lines=999999 --dry-run",
])
def test_lines_bounds_rejected(command):
    result = run_wrapper(command)
    assert result.returncode != 0
    assert "must be" in result.stderr


def test_journal_logs_uses_narrow_root_helper():
    data = load_yaml()
    tool = next(t for t in data["tools"] if t["name"] == "journal_logs")
    assert tool["execute"] == (
        "sudo /usr/local/lib/openhands-broker/journal-logs "
        "{{service}} {{lines}} 2>&1"
    )


@pytest.mark.parametrize("args", [
    [],
    ["openhands-agent"],
    ["openhands-agent", "1", "extra"],
    ["ssh.service", "10"],
    ["openhands-agent", "not-an-integer"],
    ["openhands-agent", "0"],
    ["openhands-agent", "501"],
])
def test_journal_helper_rejects_invalid_scope(args):
    result = subprocess.run(
        ["bash", JOURNAL_HELPER_SH, *args],
        text=True,
        capture_output=True,
        timeout=5,
    )
    assert result.returncode == 64


def test_journal_helper_has_fixed_journalctl_boundary():
    with open(JOURNAL_HELPER_SH) as f:
        helper = f.read()
    assert "exec /usr/bin/journalctl" in helper
    assert '--unit="${service}"' in helper
    assert '--lines="${line_count}"' in helper
    assert "systemd-journal" not in helper
    assert " adm" not in helper


# ======================================================================
# 6. Injection protection patterns
# ======================================================================

INJECTION_PATTERNS = [
    "; rm -rf /",
    "& rm -rf /",
    "&& rm -rf /",
    "$(rm -rf /)",
    "`rm -rf /`",
    "`ls`",
    "$(cat /etc/passwd)",
    "../etc/passwd",
    "/etc/passwd",
    "service=openhands-agent; ls",
]

def test_tools_yaml_no_injection_in_commands():
    """Команды в tools.yaml не должны содержать очевидных injection-паттернов
    в execute/verify/rollback сами по себе"""
    commands = [
        "system_status service=/etc/passwd --dry-run",
        "system_status service=../etc/passwd --dry-run",
        "system_status service=openhands-agent;id --dry-run",
        "journal_logs lines=not-an-integer --dry-run",
        "service_restart service=ssh --dry-run",
    ]
    for command in commands:
        result = run_wrapper(command)
        assert result.returncode != 0, command


# ======================================================================
# 7. Forced command blocks shell
# ======================================================================

def test_forced_command_prevents_shell():
    """sshd needs a working login shell to launch the forced command."""
    data = load_yaml()
    assert data["user"] == "openhands-broker"
    with open(os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")) as f:
        setup_content = f.read()
    assert 'command="/usr/local/lib/openhands-broker/broker-wrapper.sh"' in setup_content
    assert 'from="10.89.0.2",restrict,command=' in setup_content
    assert "Match User openhands-broker" in setup_content
    assert "ForceCommand /usr/local/lib/openhands-broker/broker-wrapper.sh" in setup_content
    assert "DisableForwarding yes" in setup_content
    assert "PasswordAuthentication no" in setup_content
    assert "PermitTTY no" in setup_content
    assert "--shell /bin/bash" in setup_content
    assert "usermod -s /bin/bash" in setup_content
    assert "/usr/sbin/nologin" not in setup_content


def test_broker_account_is_not_locked_for_public_key_auth():
    setup_path = os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")
    with open(setup_path) as f:
        setup = f.read()
    assert "usermod -p '*NP*' \"${BROKER_USER}\"" in setup
    assert "usermod -L" not in setup
    assert "AuthenticationMethods publickey" in setup
    assert "PasswordAuthentication no" in setup
    assert "KbdInteractiveAuthentication no" in setup


def test_authorized_keys_path_is_readable_but_not_writable_by_broker():
    setup_path = os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")
    with open(setup_path) as f:
        setup = f.read()
    assert 'install -d -o root -g root -m 711 "${BROKER_HOME}"' in setup
    assert 'install -d -o root -g root -m 711 "${SSH_DIR}"' in setup
    assert 'chown root:"${BROKER_USER}" "${AUTH_KEYS_TMP}"' in setup
    assert 'chmod 440 "${AUTH_KEYS_TMP}"' in setup


def test_setup_is_fail_closed_before_mutation():
    setup_path = os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")
    with open(setup_path) as f:
        setup = f.read()
    assert setup.index('[ "$(id -u)" -eq 0 ]') < setup.index('exec 9>"${LOCKFILE}"')
    assert 'LOCK_DIR="/run/lock/openhands-broker"' in setup
    assert "git diff --quiet --ignore-submodules HEAD --" in setup
    assert "git diff --cached --quiet --ignore-submodules HEAD --" in setup
    assert "git ls-files --others --exclude-standard" in setup
    assert "git hash-object" in setup


def test_sudoers_is_validated_before_atomic_install():
    setup_path = os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")
    with open(setup_path) as f:
        setup = f.read()
    visudo = setup.index('visudo -cf "${SUDOERS_TMP}"')
    install = setup.index('mv -f "${SUDOERS_TMP}" "${SUDOERS_FILE}"')
    assert visudo < install
    assert "cat > \"${SUDOERS_FILE}\"" not in setup


def test_journal_access_is_narrow_and_root_controlled():
    setup_path = os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")
    with open(setup_path) as f:
        setup = f.read()
    assert 'deployment/broker/journal-logs.sh' in setup
    assert 'install -o root -g root -m 755 \\' in setup
    assert '"${JOURNAL_HELPER_SRC}" "${BROKER_LIB}/journal-logs"' in setup
    assert (
        "openhands-broker ALL=(root) NOPASSWD: "
        "/usr/local/lib/openhands-broker/journal-logs"
    ) in setup
    assert 'sudo -n "${BROKER_LIB}/journal-logs" openhands-agent 1' in setup
    assert "usermod -a" not in setup
    assert "systemd-journal" not in setup
    assert " adm" not in setup


def test_broker_key_permissions_match_container_identity():
    setup_path = os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")
    prepare_path = os.path.join(REPO_ROOT, "deployment", "scripts", "prepare.sh")
    runtime_path = os.path.join(REPO_ROOT, "deployment", "scripts", "validate-runtime.sh")
    with open(setup_path) as f:
        setup = f.read()
    with open(prepare_path) as f:
        prepare = f.read()
    with open(runtime_path) as f:
        runtime = f.read()
    assert 'chown root:10001 "${CLIENT_KEY}"' in setup
    assert 'chmod 0640 "${CLIENT_KEY}"' in setup
    assert 'chown root:10001 "${BROKER_KEY}"' in prepare
    assert 'chmod 0640 "${BROKER_KEY}"' in prepare
    assert '"0:10001:640"' in runtime


def test_prepare_preserves_broker_key_across_repeated_restart():
    prepare_path = os.path.join(REPO_ROOT, "deployment", "scripts", "prepare.sh")
    with open(prepare_path) as f:
        prepare = f.read()
    assert 'BROKER_KEY="${BASE}/secrets/broker-mini-server.key"' in prepare
    assert 'chown -R "${HOST_OWNER}" "${BASE}/secrets"' not in prepare
    assert '! -path "${BROKER_KEY}"' in prepare
    general_secrets = prepare.index('find "${BASE}/secrets"')
    restore_owner = prepare.index('chown root:10001 "${BROKER_KEY}"')
    restore_mode = prepare.index('chmod 0640 "${BROKER_KEY}"')
    assert general_secrets < restore_owner < restore_mode


def test_runtime_validator_fails_closed_on_broker_file_permissions():
    runtime_path = os.path.join(REPO_ROOT, "deployment", "scripts", "validate-runtime.sh")
    with open(runtime_path) as f:
        runtime = f.read()
    assert 'BROKER_KEY_STATE="$(stat -c \'%u:%g:%a\' "${BROKER_KEY}")"' in runtime
    assert '[ "${BROKER_KEY_STATE}" = "0:10001:640" ]' in runtime
    assert 'KNOWN_HOSTS_STATE="$(stat -c \'%u:%g:%a\' "${BROKER_KNOWN_HOSTS}")"' in runtime
    assert '[ "${KNOWN_HOSTS_STATE}" = "0:10001:640" ]' in runtime
    assert '"${BROKER_KEY}:/secrets/broker-mini-server.key:ro"' in runtime
    assert (
        '"${BROKER_KNOWN_HOSTS}:/home/openhands/.ssh/known_hosts:ro"'
        in runtime
    )
    assert "work-workspace" in runtime
    assert "test-workspace" not in runtime
    compose_validation = runtime.index('docker compose -f "${COMPOSE_FILE}" config')
    assert runtime.index('BROKER_KEY_STATE=') < compose_validation
    assert runtime.index('KNOWN_HOSTS_STATE=') < compose_validation


def test_setup_atomically_delivers_authorized_lifecycle_scripts():
    setup_path = os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")
    with open(setup_path) as f:
        setup = f.read()
    for source in (
        "deployment/scripts/prepare.sh",
        "deployment/scripts/validate-runtime.sh",
        "deployment/scripts/health-watchdog.sh",
        "deployment/scripts/seed-config.sh",
        "deployment/config/settings.json",
        "deployment/config/profiles/deepseek-chat.json",
        "deployment/config/agent-profiles/default.json",
    ):
        assert source in setup
    assert 'PREPARE_TARGET="/srv/openhands-agent/deployment/scripts/prepare.sh"' in setup
    assert (
        'VALIDATE_RUNTIME_TARGET="/srv/openhands-agent/deployment/scripts/validate-runtime.sh"'
        in setup
    )
    assert (
        'HEALTH_WATCHDOG_TARGET="/srv/openhands-agent/deployment/scripts/health-watchdog.sh"'
        in setup
    )
    assert "77cece874846d56b058a9f0932f8188674ec11c3" in setup
    assert "6835ee74594890cfb66bca9d4ddcdb1b14baf3ec" in setup
    assert "11707aa434ceb324dec704b3e47374604a2f45c6" in setup
    assert "diverges from every authorized update base" in setup
    assert setup.count("require_authorized_runtime_target") >= 7
    assert setup.index('PREPARE_TMP="$(mktemp') < setup.index(
        'mv -f "${PREPARE_TMP}" "${PREPARE_TARGET}"'
    )
    assert setup.index('VALIDATE_RUNTIME_TMP="$(mktemp') < setup.index(
        'mv -f "${VALIDATE_RUNTIME_TMP}" "${VALIDATE_RUNTIME_TARGET}"'
    )
    assert setup.index('HEALTH_WATCHDOG_TMP="$(mktemp') < setup.index(
        'mv -f "${HEALTH_WATCHDOG_TMP}" "${HEALTH_WATCHDOG_TARGET}"'
    )


def test_clean_setup_installs_complete_prepare_dependency_chain():
    setup_path = os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")
    prepare_path = os.path.join(REPO_ROOT, "deployment", "scripts", "prepare.sh")
    seed_path = os.path.join(REPO_ROOT, "deployment", "scripts", "seed-config.sh")
    with open(setup_path) as f:
        setup = f.read()
    with open(prepare_path) as f:
        prepare = f.read()
    with open(seed_path) as f:
        seed = f.read()

    dependencies = {
        "SEED_CONFIG_TARGET": "deployment/scripts/seed-config.sh",
        "SETTINGS_TEMPLATE_TARGET": "deployment/config/settings.json",
        "DEEPSEEK_TEMPLATE_TARGET": "deployment/config/profiles/deepseek-chat.json",
        "DEFAULT_AGENT_TEMPLATE_TARGET": "deployment/config/agent-profiles/default.json",
    }
    for variable, relative_target in dependencies.items():
        assert f'{variable}="/srv/openhands-agent/{relative_target}"' in setup
        assert os.path.isfile(os.path.join(REPO_ROOT, relative_target))
    assert 'TARGET="/srv/openhands-agent/config' not in setup

    assert '"${SCRIPT_DIR}/seed-config.sh"' in prepare
    assert '"${SCRIPT_DIR}/seed-config.sh" --force' not in prepare
    assert 'find "${BASE}/config" -mindepth 1 -maxdepth 1 -print -quit' in prepare
    assert "Existing server-side Canvas config preserved" in prepare
    assert prepare.index("Existing server-side Canvas config preserved") < prepare.index(
        '"${SCRIPT_DIR}/seed-config.sh"'
    )
    assert 'TEMPLATES="${SCRIPT_DIR}/../config"' in seed
    assert 'TARGET="${BASE}/config"' in seed
    assert 'if [ -f "${dst}" ] && [ "${FORCE}" != "true" ]' in seed
    for source in (
        '"${TEMPLATES}/settings.json"',
        '"${TEMPLATES}/profiles/deepseek-chat.json"',
        '"${TEMPLATES}/agent-profiles/default.json"',
    ):
        assert source in seed

    assert "require_absent_or_current_runtime_target" in setup
    assert 'if [ ! -e "${target_path}" ] && [ ! -L "${target_path}" ]; then' in setup
    assert '[ "${target_hash}" = "${source_hash}" ]' in setup
    assert "diverges from the verified commit" in setup
    dependency_installs = [
        setup.index('mv -f "${SETTINGS_TEMPLATE_TMP}" "${SETTINGS_TEMPLATE_TARGET}"'),
        setup.index('mv -f "${DEEPSEEK_TEMPLATE_TMP}" "${DEEPSEEK_TEMPLATE_TARGET}"'),
        setup.index('mv -f "${DEFAULT_AGENT_TEMPLATE_TMP}" "${DEFAULT_AGENT_TEMPLATE_TARGET}"'),
        setup.index('mv -f "${SEED_CONFIG_TMP}" "${SEED_CONFIG_TARGET}"'),
    ]
    prepare_install = setup.index('mv -f "${PREPARE_TMP}" "${PREPARE_TARGET}"')
    assert all(install < prepare_install for install in dependency_installs)


# ======================================================================
# 8. Secrets not exposed in dry-run/logs
# ======================================================================

def test_secrets_not_in_dry_run_or_logs():
    """Проверяем что wrapper не выводит секреты в dry-run"""
    with open(WRAPPER_SH) as f:
        wrapper = f.read()
    assert "secrets masked" in wrapper
    assert "Would execute (secrets masked)" in wrapper
    assert "| while IFS=" not in wrapper

    with tempfile.TemporaryDirectory() as broker_base:
        os.mkdir(os.path.join(broker_base, "secrets"))
        secret_value = "test-secret-value"
        with open(os.path.join(broker_base, "secrets", "TOKEN"), "w") as f:
            f.write(secret_value)
        registry = {
            "tools": [{
                "name": "secret_probe",
                "risk": "A",
                "params": {},
                "execute": "printf '%s' '{{secret:TOKEN}}'",
                "verify": None,
                "rollback": None,
                "secrets": ["TOKEN"],
            }]
        }
        with open(os.path.join(broker_base, "tools.yaml"), "w") as f:
            yaml.safe_dump(registry, f)
        result = run_wrapper("secret_probe --dry-run", broker_base)
        assert result.returncode == 0
        assert "secrets masked" in result.stdout
        assert secret_value not in result.stdout
        assert secret_value not in result.stderr
        assert secret_value not in result.audit_log


def test_audit_failure_blocks_execution():
    with tempfile.TemporaryDirectory() as broker_base:
        marker = os.path.join(broker_base, "executed")
        write_registry(broker_base, {
            "name": "audit_probe",
            "risk": "A",
            "params": {},
            "execute": f"touch {marker}",
            "verify": None,
            "rollback": None,
            "secrets": [],
        })
        result = run_wrapper("audit_probe", broker_base, audit_ok=False)
        assert result.returncode == 70
        assert "audit unavailable" in result.stderr
        assert not os.path.exists(marker)


def test_precheck_failure_blocks_execution():
    with tempfile.TemporaryDirectory() as broker_base:
        marker = os.path.join(broker_base, "executed")
        write_registry(broker_base, {
            "name": "precheck_probe",
            "risk": "A",
            "params": {},
            "check": "exit 9",
            "execute": f"touch {marker}",
            "verify": None,
            "rollback": None,
            "secrets": [],
        })
        result = run_wrapper("precheck_probe", broker_base)
        assert result.returncode == 9
        assert "pre-check failed" in result.stderr
        assert "PRECHECK_FAILED" in result.audit_log
        assert not os.path.exists(marker)


def test_failed_execute_has_failed_audit_status():
    with tempfile.TemporaryDirectory() as broker_base:
        write_registry(broker_base, {
            "name": "failure_probe",
            "risk": "A",
            "params": {},
            "execute": "exit 7",
            "verify": None,
            "rollback": None,
            "secrets": [],
        })
        result = run_wrapper("failure_probe", broker_base)
        assert result.returncode == 7
        assert "EXECUTE_FAILED" in result.audit_log
        records = [json.loads(line) for line in result.audit_log.splitlines()]
        assert records[-1]["status"] == "EXECUTE_FAILED"
        assert records[-1]["exit_code"] == 7


def test_output_is_bounded():
    with tempfile.TemporaryDirectory() as broker_base:
        write_registry(broker_base, {
            "name": "output_probe",
            "risk": "A",
            "params": {},
            "execute": "yes X",
            "verify": None,
            "rollback": None,
            "secrets": [],
        })
        result = run_wrapper("output_probe", broker_base)
        assert result.returncode == 125
        assert "output limit exceeded" in result.stdout
        assert len(result.stdout.encode()) < 67000
        assert "EXECUTE_FAILED" in result.audit_log


# ======================================================================
# 9. Verify and rollback structure
# ======================================================================

def test_verify_and_rollback():
    """Проверка что verify и rollback корректно описаны"""
    data = load_yaml()
    for t in data["tools"]:
        name = t["name"]
        execute = t.get("execute", "")
        verify = t.get("verify")
        rollback = t.get("rollback")
        # backup_create имеет verify но не rollback — ок
        if "backup" in name and not rollback:
            continue
        # Инструменты уровня A обычно не имеют verify/rollback — ок
        if t["risk"] == "A":
            continue
        if t["risk"] == "B" and name != "backup_create":
            assert verify, f"{name} must define verify"
            assert rollback, f"{name} must define rollback"


def test_systemd_verification_is_exact():
    data = load_yaml()
    by_name = {tool["name"]: tool for tool in data["tools"]}
    for name in ("service_restart", "service_start"):
        assert by_name[name]["verify"] == "systemctl is-active --quiet {{service}}"
        assert "grep" not in by_name[name]["verify"]
    assert ' = inactive' in by_name["service_stop"]["verify"]


# ======================================================================
# 10. All 13 tools are present
# ======================================================================

EXPECTED_TOOLS = {
    "ping", "system_status", "journal_logs",
    "docker_ps", "docker_compose_ps", "docker_compose_logs",
    "disk_usage", "memory_usage",
    "validate_runtime", "backup_create",
    "service_restart", "service_start", "service_stop",
}

def test_all_tools_present():
    """Все 13 инструментов должны быть в tools.yaml"""
    names = set(get_tool_names())
    assert names == EXPECTED_TOOLS, f"Missing: {EXPECTED_TOOLS - names}, Extra: {names - EXPECTED_TOOLS}"


def test_risk_levels_assigned():
    """Проверка что уровни риска назначены верно"""
    data = load_yaml()
    for t in data["tools"]:
        name = t["name"]
        risk = t["risk"]
        # Инструменты диагностики — A
        if name in ("ping", "system_status", "journal_logs", "docker_ps",
                     "docker_compose_ps", "docker_compose_logs",
                     "disk_usage", "memory_usage", "validate_runtime"):
            assert risk == "A", f"{name} should be risk A, got {risk}"
        # Операции изменения — B
        if name in ("service_restart", "service_start", "service_stop", "backup_create"):
            assert risk == "B", f"{name} should be risk B, got {risk}"


# ======================================================================
# 11. Топология
# ======================================================================

def test_topology_correct():
    """Проверка что host и server соответствуют архитектуре"""
    data = load_yaml()
    assert data["host"] == "10.89.0.1", f"Expected 10.89.0.1, got {data['host']}"
    assert data["server"] == "mini-server"
    assert data["user"] == "openhands-broker"


# ======================================================================
# 12. Docker commands use sudo
# ======================================================================

def test_docker_commands_use_sudo():
    """Все docker-команды должны использовать sudo"""
    data = load_yaml()
    docker_tools = ["docker_ps", "docker_compose_ps", "docker_compose_logs"]
    for t in data["tools"]:
        if t["name"] in docker_tools:
            assert t["execute"].startswith("sudo"), f"{t['name']} should use sudo: {t['execute']}"


def test_docker_ps_matches_exact_sudoers_rule():
    data = load_yaml()
    docker_ps = next(t for t in data["tools"] if t["name"] == "docker_ps")
    assert docker_ps["execute"] == "sudo docker ps 2>&1"
    setup = os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")
    with open(setup) as f:
        setup_content = f.read()
    assert "NOPASSWD: /usr/bin/docker ps\n" in setup_content


def test_compose_mounts_only_pinned_broker_ssh_files():
    compose = os.path.join(REPO_ROOT, "deployment", "compose.yaml")
    with open(compose) as f:
        content = f.read()
    assert "/srv/openhands-agent/secrets:/secrets" not in content
    assert "secrets/broker-mini-server.key:/secrets/broker-mini-server.key:ro" in content
    assert (
        "/etc/openhands-broker/client_known_hosts:"
        "/home/openhands/.ssh/known_hosts:ro"
    ) in content


def test_pinned_known_hosts_is_verified_and_root_controlled():
    setup = os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")
    watchdog = os.path.join(REPO_ROOT, "deployment", "scripts", "health-watchdog.sh")
    with open(setup) as f:
        content = f.read()
    with open(watchdog) as f:
        watchdog_content = f.read()
    assert 'HOST_KEY_PUBLIC="/etc/ssh/ssh_host_ed25519_key.pub"' in content
    assert 'HOST_KEY_PRIVATE="/etc/ssh/ssh_host_ed25519_key"' in content
    assert 'ssh-keygen -y -f "${HOST_KEY_PRIVATE}"' in content
    assert 'ssh-keyscan -4' not in content
    assert '"${DERIVED_HOST_FINGERPRINT}" = "${LOCAL_HOST_FINGERPRINT}"' in content
    assert '"${DERIVED_HOST_KEY}" = "${LOCAL_HOST_KEY}"' not in content
    assert 'CLIENT_KNOWN_HOSTS="${BROKER_ETC}/client_known_hosts"' in content
    assert 'chown root:10001 "${KNOWN_HOSTS_TMP}"' in content
    assert 'chmod 0640 "${KNOWN_HOSTS_TMP}"' in content
    assert 'stat -c \'%u:%g:%a\' "${BROKER_ETC}"' in content
    assert 'Pinned known_hosts parent is not root-controlled' in content
    assert 'BROKER_KNOWN_HOSTS="${BROKER_KNOWN_HOSTS:-/etc/openhands-broker/client_known_hosts}"' in watchdog_content
    assert '"${SSH_KEYSCAN_BIN}" -4 -T 2 -p "${BROKER_PORT}" -t ed25519 "${BROKER_HOST}"' in watchdog_content
    assert '"${observed_fingerprint}" != "${pinned_fingerprint}"' in watchdog_content
    assert "accept-new" not in content
    assert "StrictHostKeyChecking=no" not in content
    assert "accept-new" not in watchdog_content
    assert "StrictHostKeyChecking=no" not in watchdog_content


def test_host_key_fingerprint_ignores_comment_and_line_ending():
    with tempfile.TemporaryDirectory() as key_dir:
        private_key = os.path.join(key_dir, "host_ed25519")
        public_key = private_key + ".pub"
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "original", "-f", private_key],
            check=True,
            timeout=5,
        )
        with open(public_key, encoding="ascii") as f:
            key_type, key_blob, _ = f.read().strip().split(maxsplit=2)
        with open(public_key, "wb") as f:
            f.write(f"{key_type} {key_blob} different-comment\r\n".encode("ascii"))

        derived = subprocess.run(
            ["ssh-keygen", "-y", "-f", private_key],
            check=True,
            text=True,
            capture_output=True,
            timeout=5,
        ).stdout
        derived_fingerprint = subprocess.run(
            ["ssh-keygen", "-lf", "-", "-E", "sha256"],
            input=derived,
            check=True,
            text=True,
            capture_output=True,
            timeout=5,
        ).stdout.split()[1]
        public_fingerprint = subprocess.run(
            ["ssh-keygen", "-lf", public_key, "-E", "sha256"],
            check=True,
            text=True,
            capture_output=True,
            timeout=5,
        ).stdout.split()[1]

        assert derived.strip() != f"{key_type} {key_blob} different-comment"
        assert derived_fingerprint == public_fingerprint


def test_host_key_mismatch_is_fail_closed_after_runtime_start():
    setup = os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")
    watchdog = os.path.join(REPO_ROOT, "deployment", "scripts", "health-watchdog.sh")
    with open(setup) as f:
        content = f.read()
    with open(watchdog) as f:
        watchdog_content = f.read()
    assert "Cannot read live ED25519 host key" not in content
    assert "Live SSH host fingerprint does not match" not in content
    assert 'verify_broker_host_key' in watchdog_content
    assert 'Live broker SSH host key не совпадает с pinned key' in watchdog_content
    container_check = watchdog_content.index(
        'if ! "${DOCKER_BIN}" ps --format \'{{.Names}}\''
    )
    live_verify = watchdog_content.index("verify_broker_host_key", container_check)
    assert container_check < live_verify
    runtime = os.path.join(REPO_ROOT, "deployment", "scripts", "validate-runtime.sh")
    with open(runtime) as f:
        runtime_content = f.read()
    assert "Pinned broker host key mismatch; refusing to start Canvas" in runtime_content


def test_stopped_service_without_bridge_can_bootstrap_then_verify_endpoint():
    setup = os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")
    watchdog = os.path.join(REPO_ROOT, "deployment", "scripts", "health-watchdog.sh")
    supervisor = os.path.join(REPO_ROOT, "deployment", "scripts", "run-supervised.sh")
    with open(setup) as f:
        setup_content = f.read()
    with open(watchdog) as f:
        watchdog_content = f.read()
    with open(supervisor) as f:
        supervisor_content = f.read()

    assert 'ssh-keyscan -4' not in setup_content
    assert '"${DERIVED_HOST_FINGERPRINT}" = "${LOCAL_HOST_FINGERPRINT}"' in setup_content
    assert 'mv -f "${KNOWN_HOSTS_TMP}" "${CLIENT_KNOWN_HOSTS}"' in setup_content
    assert 'deployment/scripts/health-watchdog.sh' in setup_content
    assert 'mv -f "${HEALTH_WATCHDOG_TMP}" "${HEALTH_WATCHDOG_TARGET}"' in setup_content

    container_found = watchdog_content.index('echo "[watchdog] Контейнер найден."')
    endpoint_verify = watchdog_content.index("verify_broker_host_key", container_found)
    endpoint_scan = watchdog_content.index('"${SSH_KEYSCAN_BIN}" -4 -T 2')
    assert container_found < endpoint_verify
    assert endpoint_scan < endpoint_verify
    assert 'HOST_KEY_RETRIES="${WATCHDOG_HOST_KEY_RETRIES:-10}"' in watchdog_content
    assert 'return 1' in watchdog_content[endpoint_scan:endpoint_verify]
    assert (
        'WATCHDOG="${WATCHDOG:-/srv/openhands-agent/deployment/scripts/health-watchdog.sh}"'
        in supervisor_content
    )


def test_watchdog_verifies_live_endpoint_and_rejects_mismatch():
    watchdog = os.path.join(REPO_ROOT, "deployment", "scripts", "health-watchdog.sh")
    with tempfile.TemporaryDirectory() as test_dir:
        docker = os.path.join(test_dir, "docker")
        keyscan = os.path.join(test_dir, "ssh-keyscan")
        keygen = os.path.join(test_dir, "ssh-keygen")
        known_hosts = os.path.join(test_dir, "known_hosts")
        with open(docker, "w") as f:
            f.write(
                "#!/usr/bin/bash\n"
                "if [ \"$1\" = ps ]; then echo openhands-agent; exit 0; fi\n"
                "if [ \"$1\" = inspect ]; then echo unknown; exit 0; fi\n"
                "exit 2\n"
            )
        with open(keyscan, "w") as f:
            f.write(
                "#!/usr/bin/bash\n"
                "echo '10.89.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockKey'\n"
            )
        with open(known_hosts, "w") as f:
            f.write("[10.89.0.1]:22 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockKey\n")
        os.chmod(docker, 0o755)
        os.chmod(keyscan, 0o755)

        def run_watchdog(observed_fingerprint):
            with open(keygen, "w") as f:
                f.write(
                    "#!/usr/bin/bash\n"
                    "case \"$2\" in\n"
                    f"  {known_hosts}) fingerprint=SHA256:Pinned ;;\n"
                    f"  *) fingerprint={observed_fingerprint} ;;\n"
                    "esac\n"
                    "echo \"256 $fingerprint broker-host (ED25519)\"\n"
                )
            os.chmod(keygen, 0o755)
            env = os.environ.copy()
            env.update({
                "DOCKER_BIN": docker,
                "SSH_KEYSCAN_BIN": keyscan,
                "SSH_KEYGEN_BIN": keygen,
                "BROKER_KNOWN_HOSTS": known_hosts,
                "WATCHDOG_START_PERIOD": "0",
                "WATCHDOG_HOST_KEY_RETRIES": "1",
                "WATCHDOG_HOST_SCAN_TMP_DIR": test_dir,
            })
            return subprocess.run(
                ["bash", watchdog],
                env=env,
                text=True,
                capture_output=True,
                timeout=5,
            )

        matching = run_watchdog("SHA256:Pinned")
        assert "Broker SSH host key подтверждён" in matching.stdout, (
            matching.stdout + matching.stderr
        )
        mismatch = run_watchdog("SHA256:Mismatch")
        assert mismatch.returncode == 1
        assert "не совпадает с pinned key" in mismatch.stdout
        assert "Broker SSH host key подтверждён" not in mismatch.stdout


def test_broker_client_keeps_strict_host_key_checking():
    stage_doc = os.path.join(
        REPO_ROOT,
        "docs",
        "План Этапа 4D — Постоянные инструменты агента.md",
    )
    with open(stage_doc) as f:
        content = f.read()
    assert "StrictHostKeyChecking=yes" in content
    assert "StrictHostKeyChecking=no" not in content
    assert "accept-new" not in content


def test_canvas_image_contains_minimal_ssh_client():
    dockerfile = os.path.join(
        REPO_ROOT, "deployment", "broker-client", "Dockerfile"
    )
    with open(dockerfile) as f:
        content = f.read()
    assert "agent-canvas:1.6.1@sha256:" in content
    assert "openssh-client" in content
    assert "USER openhands" in content


def test_firewall_allows_only_broker_host_port():
    firewall = os.path.join(REPO_ROOT, "deployment", "network", "apply-egress-rules.sh")
    with open(firewall) as f:
        content = f.read()
    active = [
        line.strip() for line in content.splitlines()
        if line.strip().startswith("iptables ")
    ]
    assert any(
        '"${EGRESS_CHAIN}" -d 10.89.0.1 -p tcp --dport 22 -j RETURN' in line
        for line in active
    )
    assert any(
        '"${INPUT_CHAIN}" -d 10.89.0.1 -p tcp --dport 22 -j ACCEPT' in line
        for line in active
    )
