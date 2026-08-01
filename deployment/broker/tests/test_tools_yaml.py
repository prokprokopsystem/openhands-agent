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


def test_broker_key_permissions_match_container_identity():
    setup_path = os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")
    runtime_path = os.path.join(REPO_ROOT, "deployment", "scripts", "validate-runtime.sh")
    with open(setup_path) as f:
        setup = f.read()
    with open(runtime_path) as f:
        runtime = f.read()
    assert 'chown root:10001 "${CLIENT_KEY}"' in setup
    assert 'chmod 0640 "${CLIENT_KEY}"' in setup
    assert '"0:10001:640"' in runtime


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


def test_compose_mounts_only_broker_key():
    compose = os.path.join(REPO_ROOT, "deployment", "compose.yaml")
    with open(compose) as f:
        content = f.read()
    assert "/srv/openhands-agent/secrets:/secrets" not in content
    assert "secrets/broker-mini-server.key:/secrets/broker-mini-server.key:ro" in content


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
