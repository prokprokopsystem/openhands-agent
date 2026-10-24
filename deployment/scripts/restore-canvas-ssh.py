#!/usr/bin/env python3
"""Restore ordinary SSH from retained Canvas tools image; no new keys/backups."""
import json
import os
import pathlib
import re
import subprocess
import sys
import time

BASE = pathlib.Path('/srv/openhands-agent')
COMPOSE = BASE / 'deployment/compose.yaml'
FIREWALL = BASE / 'deployment/network/apply-egress-rules.sh'
CLIENT = BASE / 'ssh-client'
KEY = BASE / 'secrets/broker-mini-server.key'
SOURCE_IMAGE = '293042314e9e'
IMAGE_TAG = 'openhands-agent-canvas-ssh:1.6.1-restored'
BASE_IMAGE = 'ghcr.io/openhands/agent-canvas:1.6.1@sha256:fc24163754bee2ab0115b117d57512cc01b4d99770e7ac17c3607e76290deeb6'
RULE = ['-s', '10.89.0.2/32', '-d', '10.89.0.1/32', '-p', 'tcp', '--dport', '22', '-j', 'ACCEPT']
CONFIG = '''Host mini-server
    HostName 10.89.0.1
    User igor
    IdentityFile /run/openhands-ssh-key
    IdentitiesOnly yes
    BatchMode yes
    ConnectTimeout 10
    StrictHostKeyChecking yes
    UserKnownHostsFile /home/openhands/.ssh/known_hosts
    HostKeyAlgorithms ssh-ed25519
    UpdateHostKeys no
'''


def run(args, *, check=True, timeout=45):
    # Never print commands or arbitrary stderr: compose may contain environment.
    return subprocess.run(args, capture_output=True, text=True, check=check, timeout=timeout)


def patch_compose(text):
    old = '    image: ' + BASE_IMAGE
    new = '    image: ' + IMAGE_TAG + '\n    pull_policy: never'
    mounts = ('      - /srv/openhands-agent/ssh-client:/home/openhands/.ssh:ro\n'
              '      - /srv/openhands-agent/secrets/broker-mini-server.key:/run/openhands-ssh-key:ro')
    anchor = '      - /srv/openhands-agent/docs:/docs:ro'
    if old not in text or text.count(old) != 1 or 'pull_policy:' in text:
        raise RuntimeError('Compose отличается от показанного исходного файла; ничего не применять')
    if text.count(anchor) != 1 or 'ssh-client:' in text or '/run/openhands-ssh-key' in text:
        raise RuntimeError('Неожиданные mounts; ничего не применять')
    return text.replace(old, new, 1).replace(anchor, anchor + '\n' + mounts, 1)


def patch_firewall(text):
    anchor = 'iptables -A "${INPUT_CHAIN}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n'
    rule = 'iptables -A "${INPUT_CHAIN}" ' + ' '.join(RULE) + '\n'
    if text.count(anchor) != 1 or rule in text:
        raise RuntimeError('Firewall отличается от показанного файла; ничего не применять')
    return text.replace(anchor, anchor + '# Ordinary SSH: Canvas to this host only.\n' + rule, 1).replace(
        '# New connections from OpenHands to the mini-server itself are forbidden.',
        '# Only the explicit Canvas-to-host SSH connection is allowed below.')


def validate_identity(output):
    lines = output.splitlines()
    if 'mini-server' not in lines or not re.search(r'uid=1000\(igor\)', output):
        raise RuntimeError('SSH не подтвердил ожидаемый хост mini-server и пользователя igor')


def inspect(name):
    return json.loads(run(['docker', 'inspect', name]).stdout)[0]


def main():
    if os.geteuid() != 0:
        raise RuntimeError('Запустить через sudo python3')
    original_compose = COMPOSE.read_text()
    original_firewall = FIREWALL.read_text()
    new_compose = patch_compose(original_compose)
    new_firewall = patch_firewall(original_firewall)
    current = inspect('openhands-agent')
    if current['Config']['Image'] != BASE_IMAGE or not current['State']['Running']:
        raise RuntimeError('Текущий Canvas не соответствует проверенному исходному состоянию')
    net = current['NetworkSettings']['Networks']['openhands-net']
    if (net['IPAddress'], net['Gateway']) != ('10.89.0.2', '10.89.0.1'):
        raise RuntimeError('Адрес или gateway сети изменился')
    source = inspect(SOURCE_IMAGE)
    live_image = inspect(current['Image'])
    for field in ('Entrypoint', 'Cmd'):
        if source['Config'].get(field) != live_image['Config'].get(field):
            raise RuntimeError('Сохранённый image меняет команду запуска Canvas')
    if CLIENT.exists():
        raise RuntimeError('Каталог ssh-client уже существует; не перезаписываю его')
    if KEY.is_symlink() or not KEY.is_file() or (KEY.stat().st_uid, KEY.stat().st_gid, KEY.stat().st_mode & 0o777) != (0, 10001, 0o640):
        raise RuntimeError('Метаданные существующего ключа отличаются от проверенных')
    hostpub = pathlib.Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()
    if len(hostpub) < 2 or hostpub[0] != 'ssh-ed25519':
        raise RuntimeError('Не найден локальный ED25519 host key')
    sshd = run(['/usr/sbin/sshd', '-T']).stdout
    if 'hostkey /etc/ssh/ssh_host_ed25519_key\n' not in sshd:
        raise RuntimeError('SSHD использует другой host key; остановлено без изменения')
    run(['/usr/sbin/sshd', '-t'])
    run(['iptables', '-nL', 'OPENHANDS-INPUT'])
    rule_exists = run(['iptables', '-C', 'OPENHANDS-INPUT', *RULE], check=False).returncode == 0
    alias_exists = run(['docker', 'image', 'inspect', IMAGE_TAG], check=False).returncode == 0
    if alias_exists:
        raise RuntimeError('Имя целевого image уже занято; не заменяю его')
    changed = False
    client_created = False
    rule_added = False
    tagged = False
    try:
        CLIENT.mkdir(mode=0o750)
        client_created = True
        os.chown(CLIENT, 0, 10001)
        for name, content in [('config', CONFIG), ('known_hosts', '10.89.0.1 ' + ' '.join(hostpub[:2]) + '\n')]:
            p = CLIENT / name
            p.write_text(content)
            os.chown(p, 0, 10001)
            p.chmod(0o640)
        if not rule_exists:
            run(['iptables', '-I', 'OPENHANDS-INPUT', '1', *RULE])
            rule_added = True
        print('Проверяю обычный SSH до изменения работающего Canvas...', flush=True)
        test = run(['docker', 'run', '--rm', '--network', 'container:openhands-agent',
                    '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
                    '--user', '10001:10001',
                    '--mount', f'type=bind,src={CLIENT},dst=/home/openhands/.ssh,readonly',
                    '--mount', f'type=bind,src={KEY},dst=/run/openhands-ssh-key,readonly',
                    '--entrypoint', '/usr/bin/ssh', source['Id'],
                    '-F', '/home/openhands/.ssh/config', 'mini-server', 'hostname && id'], check=False)
        if test.returncode:
            print(test.stderr.strip(), flush=True)
            raise RuntimeError('Проверка SSH не пройдена; Canvas не переключён')
        validate_identity(test.stdout)
        print('ПРОЙДЕНО: существующий ключ подключает к mini-server как igor', flush=True)
        run(['docker', 'tag', source['Id'], IMAGE_TAG])
        tagged = True  # An alias to existing image; no image build/download.
        changed = True
        COMPOSE.write_text(new_compose)
        FIREWALL.write_text(new_firewall)
        run(['bash', '-n', str(FIREWALL)])
        run(['docker', 'compose', '-f', str(COMPOSE), 'config', '--quiet'])
        print('Перезапускаю только openhands-agent; ожидайте до трёх минут...', flush=True)
        run(['systemctl', 'restart', 'openhands-agent.service'], timeout=240)
        deadline = time.monotonic() + 150
        while time.monotonic() < deadline:
            r = run(['docker', 'inspect', '--format', '{{.State.Health.Status}}', 'openhands-agent'], check=False)
            if r.returncode == 0 and r.stdout.strip() == 'healthy':
                break
            time.sleep(2)
        else:
            raise RuntimeError('Canvas не стал healthy после перезапуска')
        test = run(['docker', 'exec', '--user', '10001:10001', 'openhands-agent',
                    'ssh', '-F', '/home/openhands/.ssh/config', 'mini-server', 'hostname && id'], check=False)
        if test.returncode:
            print(test.stderr.strip(), flush=True)
            raise RuntimeError('SSH из восстановленного Canvas не прошёл проверку')
        validate_identity(test.stdout)
        print('ПРОЙДЕНО: Canvas healthy; SSH из рабочего контейнера действует')
        print(test.stdout.strip())
        print('IMAGE_ID=' + source['Id'])
        print('Постоянная команда агента: ssh mini-server')
        print('GitHub CLI восстановлен, но его авторизация ещё НЕ подтверждена.')
    except BaseException:
        if changed:
            COMPOSE.write_text(original_compose)
            FIREWALL.write_text(original_firewall)
        if rule_added:
            run(['iptables', '-D', 'OPENHANDS-INPUT', *RULE], check=False)
        if changed:
            print('Возвращаю исходный Canvas...', flush=True)
            run(['systemctl', 'restart', 'openhands-agent.service'], check=False, timeout=240)
        if client_created:
            for name in ('config', 'known_hosts'):
                (CLIENT / name).unlink(missing_ok=True)
            CLIENT.rmdir()
        if tagged:
            run(['docker', 'image', 'rm', IMAGE_TAG], check=False)
        print('Постоянные файлы восстановлены; ключ и authorized_keys не изменялись.', flush=True)
        raise


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        if isinstance(e, subprocess.CalledProcessError):
            print('НЕ ПРОЙДЕНО: служебная команда завершилась с кодом', e.returncode)
        elif isinstance(e, subprocess.TimeoutExpired):
            print('НЕ ПРОЙДЕНО: превышено время ожидания')
        else:
            print('НЕ ПРОЙДЕНО:', e)
        sys.exit(1)
