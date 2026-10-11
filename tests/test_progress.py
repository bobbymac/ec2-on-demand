#!/usr/bin/env python3
"""Exercise terminal rendering and cleanup using fake AWS, never live AWS."""
import errno
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import time


REPO = Path(__file__).resolve().parents[1]
CLEAR = b"\r\x1b[2K"


def terminal_run(args, env, interrupt=None):
    master, slave = pty.openpty()
    process = subprocess.Popen(
        args, env=env, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    output = b""
    deadline = time.monotonic() + 12
    signalled = False
    try:
        while time.monotonic() < deadline:
            if interrupt and not signalled and CLEAR in output:
                os.killpg(process.pid, interrupt)
                signalled = True
            ready, _, _ = select.select([master], [], [], 0.1)
            if not ready:
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output += chunk
        else:
            raise AssertionError("terminal remained open: possible leaked spinner")
        return process.wait(timeout=2), output
    finally:
        # Also terminate any child left behind if a test fails.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        os.close(master)


with tempfile.TemporaryDirectory(prefix="ec2ctl-progress-") as directory:
    root = Path(directory)
    (root / "aws").symlink_to(REPO / "tests/fake-aws")
    config = root / "config"
    config.write_text(
        'AWS_REGION=test\nINSTANCE_ID=i-test\nSSH_USER=test\n'
        'TAILSCALE_HOST=test.example\nSUPPORTED_INSTANCE_TYPES=(t3.medium)\n'
        'START_TIMEOUT=2\nSTOP_TIMEOUT=1\nFORCE_STOP_TIMEOUT=1\nPOLL_INTERVAL=0.1\n'
    )
    state = root / "state"
    env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
               EC2CTL_CONFIG=str(config), FAKE_AWS_STATE_FILE=str(state),
               FAKE_AWS_LOG_FILE=str(root / "calls"), FAKE_AWS_DELAY="0.25",
               TERM="xterm")
    cli = str(REPO / "bin/ec2ctl")
    for command, initial in (("start", "stopped"), ("stop", "running")):
        state.write_text(initial)
        code, output = terminal_run([cli, command], env)
        assert code == 0, output
        assert CLEAR + b"| Waiting" in output, output
        assert CLEAR + b"/ Waiting" in output, output
        assert b"(0s)" in output, output
        final_message = b"Connect with:" if command == "start" else b"EC2 state: stopped"
        assert final_message in output, output
        assert output.rfind(CLEAR) < output.rfind(final_message), output

    state.write_text("running")
    code, output = terminal_run([cli, "stop"], dict(env, FAKE_NORMAL_STOP_STUCK="1"))
    assert code == 0 and b"requesting forced stop" in output, output
    assert state.read_text() == "stopped"

    state.write_text("pending")
    code, output = terminal_run([cli, "start"], env)
    assert code != 0 and b"before the timeout" in output, output
    assert output.rfind(CLEAR) < output.rfind(b"error:"), output

    for interruption in (signal.SIGINT, signal.SIGTERM):
        code, output = terminal_run([cli, "start"], env, interrupt=interruption)
        assert code != 0, output
        assert output.endswith(CLEAR), output

    state.write_text("running")
    calls = root / "calls"
    calls.write_text("")
    code, output = terminal_run(
        [cli, "stop"], dict(env, FAKE_NORMAL_STOP_STUCK="1"), interrupt=signal.SIGINT,
    )
    assert code != 0 and output.endswith(CLEAR), output
    assert "--force" not in calls.read_text(), "interruption triggered forced stop"

    state.write_text("running")
    result = subprocess.run([cli, "start"], env=env, capture_output=True, timeout=12)
    assert result.returncode == 0, result.stderr
    assert b"\x1b" not in result.stdout + result.stderr
    code, output = terminal_run([cli, "start"], dict(env, TERM="dumb"))
    assert code == 0 and b"\x1b" not in output, output

print("PASS: terminal animation, forced stop, timeout, interruption, and plain output")
