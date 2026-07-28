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


def run_wrapper(command, broker_base=None):
    with tempfile.TemporaryDirectory() as log_dir:
        env = os.environ.copy()
        env.update({
            "OPENHANDS_BROKER_BASE": broker_base or os.path.dirname(TOOLS_YAML),
            "OPENHANDS_BROKER_LOG_DIR": log_dir,
            "SSH_ORIGINAL_COMMAND": command,
        })
        return subprocess.run(
            ["bash", WRAPPER_SH],
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
        )


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
    # Проверка: authorized_keys должен содержать command=... в template и docs
    with open(os.path.join(os.path.dirname(__file__), "..", "setup-broker.sh")) as f:
        setup_content = f.read()
    assert 'command="/usr/local/lib/openhands-broker/broker-wrapper.sh"' in setup_content
    assert "no-port-forwarding" in setup_content
    assert "no-agent-forwarding" in setup_content
    assert "no-X11-forwarding" in setup_content
    assert "no-pty" in setup_content
    assert "--shell /bin/bash" in setup_content
    assert "usermod -s /bin/bash" in setup_content
    assert "/usr/sbin/nologin" not in setup_content


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


def test_compose_mounts_only_broker_key():
    compose = os.path.join(REPO_ROOT, "deployment", "compose.yaml")
    with open(compose) as f:
        content = f.read()
    assert "/srv/openhands-agent/secrets:/secrets" not in content
    assert "secrets/broker-mini-server.key:/secrets/broker-mini-server.key:ro" in content


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
