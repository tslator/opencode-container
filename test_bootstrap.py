#!/usr/bin/env python3

import os
import tempfile
from pathlib import Path

import bootstrap
from bootstrap import load_secrets

TERMINAL_SIZE = os.terminal_size((80, 24))


def test_secret_loading() -> None:
    with tempfile.TemporaryDirectory() as directory:
        secrets = Path(directory)
        (secrets / "anthropic-api.key").write_text("key\n", encoding="utf-8")
        (secrets / "nested").mkdir()
        environment: dict[str, str] = {"ANTHROPIC_API_KEY": "old"}

        load_secrets(secrets, environment)

        assert environment["ANTHROPIC_API_KEY"] == "key"


def test_unsupported_secret_names_are_ignored() -> None:
    with tempfile.TemporaryDirectory() as directory:
        secrets = Path(directory)
        (secrets / "PATH").write_text("not-a-path", encoding="utf-8")
        (secrets / "unrelated-file").write_text("must-not-be-read", encoding="utf-8")
        environment: dict[str, str] = {"PATH": "old"}

        load_secrets(secrets, environment)

        assert environment == {"PATH": "old"}


def test_collisions_fail() -> None:
    with tempfile.TemporaryDirectory() as directory:
        secrets = Path(directory)
        (secrets / "anthropic-api-key").write_text("one", encoding="utf-8")
        (secrets / "anthropic.api.key").write_text("two", encoding="utf-8")

        try:
            load_secrets(secrets, {})
        except RuntimeError as error:
            assert "ANTHROPIC_API_KEY" in str(error)
        else:
            raise AssertionError("expected normalized secret name collision")


class UnreadableEntry:
    name = "anthropic_api_key"

    def is_file(self) -> bool:
        return True

    def read_text(self, **_: object) -> str:
        raise PermissionError("permission denied")


class UnreadableDirectory:
    def is_dir(self) -> bool:
        return True

    def iterdir(self) -> list[UnreadableEntry]:
        return [UnreadableEntry()]


def test_unreadable_files_fail() -> None:
    try:
        load_secrets(UnreadableDirectory(), {})  # type: ignore[arg-type]
    except PermissionError:
        pass
    else:
        raise AssertionError("expected unreadable secret to fail")


def test_invalid_utf8_fails() -> None:
    with tempfile.TemporaryDirectory() as directory:
        secret = Path(directory) / "anthropic_api_key"
        secret.write_bytes(b"\xff")

        try:
            load_secrets(secret.parent, {})
        except UnicodeDecodeError:
            pass
        else:
            raise AssertionError("expected invalid UTF-8 secret to fail")


class FakeResult:
    def __init__(self, returncode: int = 0, stdout: str = "") -> None:
        self.returncode = returncode
        self.stdout = stdout


def test_beads_auto_init_skipped_without_flag() -> None:
    calls: list[list[str]] = []
    bootstrap.beads_auto_init(
        {},
        run=lambda cmd, **kwargs: calls.append(cmd) or FakeResult(),
        which=lambda name: "/usr/local/bin/bd",
        workspace=Path("/workspace"),
    )
    assert calls == []


def test_beads_auto_init_runs_when_opted_in() -> None:
    with tempfile.TemporaryDirectory() as directory:
        workspace = Path(directory)
        calls: list[tuple[list[str], object]] = []

        def run(cmd, **kwargs):
            calls.append((cmd, kwargs.get("cwd")))
            return FakeResult()

        bootstrap.beads_auto_init(
            {"OPENCODE_CONTAINER_BEADS": "1"},
            run=run,
            which=lambda name: "/usr/local/bin/bd",
            workspace=workspace,
        )
        assert calls == [(["bd", "init", "--quiet", "--role=maintainer"], str(workspace))]


def test_beads_auto_init_skipped_when_initialized() -> None:
    with tempfile.TemporaryDirectory() as directory:
        workspace = Path(directory)
        (workspace / ".beads").mkdir()
        calls: list[list[str]] = []
        bootstrap.beads_auto_init(
            {"OPENCODE_CONTAINER_BEADS": "1"},
            run=lambda cmd, **kwargs: calls.append(cmd) or FakeResult(),
            which=lambda name: "/usr/local/bin/bd",
            workspace=workspace,
        )
        assert calls == []


def test_beads_auto_init_tolerates_failure() -> None:
    with tempfile.TemporaryDirectory() as directory:
        workspace = Path(directory)
        bootstrap.beads_auto_init(
            {"OPENCODE_CONTAINER_BEADS": "1"},
            run=lambda cmd, **kwargs: FakeResult(returncode=1),
            which=lambda name: "/usr/local/bin/bd",
            workspace=workspace,
        )


def test_herdr_skipped_without_flag_or_inside_pane() -> None:
    assert not bootstrap.start_herdr([], {}, which=lambda name: "/usr/local/bin/herdr")
    assert not bootstrap.start_herdr(
        [], {"OPENCODE_CONTAINER_HERDR": "1", "HERDR_ENV": "1"}, which=lambda name: "/usr/local/bin/herdr"
    )


def test_herdr_skipped_without_binary() -> None:
    assert not bootstrap.start_herdr(
        [], {"OPENCODE_CONTAINER_HERDR": "1"}, which=lambda name: None
    )


def test_herdr_start_sequence_and_attach() -> None:
    events: list[str] = []
    created = FakeResult(stdout='{"result":{"root_pane":{"pane_id":"w1:p1"}}}')
    statuses = iter(
        [FakeResult(stdout="status: not running\n"), FakeResult(stdout="status: running\n")]
    )

    def run(cmd, **kwargs):
        if cmd[:2] == ["herdr", "status"]:
            events.append("status")
            return next(statuses)
        if cmd[:2] == ["herdr", "workspace"]:
            events.append("workspace")
            return created
        events.append(f"start:{' '.join(cmd)}")
        return FakeResult()

    with tempfile.TemporaryDirectory() as tmp:
        environ = {"OPENCODE_CONTAINER_HERDR": "1", "TMPDIR": tmp}
        started = bootstrap.start_herdr(
            ["--model", "test"],
            environ,
            run=run,
            popen=lambda cmd, **kwargs: events.append("server"),
            sleep=lambda _seconds: None,
            which=lambda name: "/usr/local/bin/herdr",
            execvp=lambda program, command: events.append(f"exec:{program}"),
            workspace=Path("/workspace"),
            get_terminal_size=lambda: TERMINAL_SIZE,
        )
        assert started
        assert events == [
            "server",
            "status",
            "status",
            "workspace",
            "start:herdr agent start main --kind opencode --pane w1:p1 -- --model test",
            "exec:herdr",
        ]
        # herdr state must live on the ephemeral dir, not the persisted volume
        assert environ["XDG_CONFIG_HOME"] == str(Path(tmp) / "herdr-config")
        assert (Path(tmp) / "herdr-config" / "herdr").is_dir()


def test_herdr_config_survives_ephemeral_state() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        persisted = Path(tmp) / "persisted" / "herdr"
        persisted.mkdir(parents=True)
        (persisted / "config.toml").write_text("[ui]\ntheme = \"dark\"\n", encoding="utf-8")
        environ = {
            "OPENCODE_CONTAINER_HERDR": "1",
            "TMPDIR": str(Path(tmp) / "tmp"),
            "XDG_CONFIG_HOME": str(Path(tmp) / "persisted"),
        }
        (Path(tmp) / "tmp").mkdir()
        bootstrap.start_herdr(
            [],
            environ,
            run=lambda cmd, **kwargs: FakeResult(stdout="status: running\n"),
            popen=lambda cmd, **kwargs: None,
            sleep=lambda _seconds: None,
            which=lambda name: "/usr/local/bin/herdr",
            execvp=lambda program, command: None,
            workspace=Path(tmp),
            get_terminal_size=lambda: TERMINAL_SIZE,
        )
        copied = Path(tmp) / "tmp" / "herdr-config" / "herdr" / "config.toml"
        assert copied.read_text(encoding="utf-8") == "[ui]\ntheme = \"dark\"\n"
        # the persisted config file itself is left untouched
        assert (persisted / "config.toml").is_file()


def test_herdr_falls_back_on_failure() -> None:
    import subprocess as _subprocess

    def run(cmd, **kwargs):
        if cmd[:2] == ["herdr", "status"]:
            return FakeResult(stdout="status: running\n")
        raise _subprocess.CalledProcessError(1, cmd)

    assert not bootstrap.start_herdr(
        [],
        {"OPENCODE_CONTAINER_HERDR": "1"},
        run=run,
        popen=lambda cmd, **kwargs: None,
        sleep=lambda _seconds: None,
        which=lambda name: "/usr/local/bin/herdr",
        workspace=Path("/tmp"),
        get_terminal_size=lambda: TERMINAL_SIZE,
    )


def test_herdr_skipped_without_usable_terminal() -> None:
    def failing_size():
        raise OSError("not a tty")

    assert not bootstrap.start_herdr(
        [],
        {"OPENCODE_CONTAINER_HERDR": "1"},
        which=lambda name: "/usr/local/bin/herdr",
        get_terminal_size=failing_size,
    )
    assert not bootstrap.start_herdr(
        [],
        {"OPENCODE_CONTAINER_HERDR": "1"},
        which=lambda name: "/usr/local/bin/herdr",
        get_terminal_size=lambda: os.terminal_size((0, 0)),
    )


def test_lifecycle_order_and_arguments() -> None:
    events: list[str] = []
    original_loader = bootstrap.load_secrets
    bootstrap.load_secrets = lambda: events.append("secrets")
    try:
        bootstrap.bootstrap(
            ["--model", "test"],
            execvp=lambda program, command: events.append(f"exec:{program}:{command}"),
        )
    finally:
        bootstrap.load_secrets = original_loader

    assert events == [
        "secrets",
        "exec:opencode:['opencode', '--standalone', '--model', 'test']",
    ]


def test_standalone_injected_by_default() -> None:
    assert bootstrap.standalone_args([]) == ["--standalone"]
    assert bootstrap.standalone_args(["--model", "test"]) == ["--standalone", "--model", "test"]
    assert bootstrap.standalone_args(["run", "hello"]) == ["--standalone", "run", "hello"]


def test_standalone_respects_explicit_server_choice() -> None:
    assert bootstrap.standalone_args(["--standalone"]) == ["--standalone"]
    assert bootstrap.standalone_args(["--server", "http://box:4096"]) == [
        "--server",
        "http://box:4096",
    ]


def test_standalone_skipped_for_subcommands_without_the_flag() -> None:
    assert bootstrap.standalone_args(["auth", "logout"]) == ["auth", "logout"]
    assert bootstrap.standalone_args(["session", "list"]) == ["session", "list"]
    assert bootstrap.standalone_args(["acp"]) == ["acp"]


def test_standalone_reaches_herdr_pane_args() -> None:
    events: list[str] = []
    created = FakeResult(stdout='{"result":{"root_pane":{"pane_id":"w1:p1"}}}')

    def run(cmd, **kwargs):
        if cmd[:2] == ["herdr", "status"]:
            return FakeResult(stdout="status: running\n")
        if cmd[:2] == ["herdr", "workspace"]:
            return created
        events.append(" ".join(cmd))
        return FakeResult()

    with tempfile.TemporaryDirectory() as tmp:
        bootstrap.start_herdr(
            bootstrap.standalone_args(["--model", "test"]),
            {"OPENCODE_CONTAINER_HERDR": "1", "TMPDIR": tmp},
            run=run,
            popen=lambda cmd, **kwargs: None,
            sleep=lambda _seconds: None,
            which=lambda name: "/usr/local/bin/herdr",
            execvp=lambda program, command: None,
            workspace=Path("/workspace"),
            get_terminal_size=lambda: TERMINAL_SIZE,
        )
    assert events == [
        "herdr agent start main --kind opencode --pane w1:p1 -- --standalone --model test"
    ]


if __name__ == "__main__":
    test_secret_loading()
    test_unsupported_secret_names_are_ignored()
    test_collisions_fail()
    test_unreadable_files_fail()
    test_invalid_utf8_fails()
    test_beads_auto_init_skipped_without_flag()
    test_beads_auto_init_runs_when_opted_in()
    test_beads_auto_init_skipped_when_initialized()
    test_beads_auto_init_tolerates_failure()
    test_herdr_skipped_without_flag_or_inside_pane()
    test_herdr_skipped_without_binary()
    test_herdr_start_sequence_and_attach()
    test_herdr_config_survives_ephemeral_state()
    test_herdr_falls_back_on_failure()
    test_herdr_skipped_without_usable_terminal()
    test_standalone_injected_by_default()
    test_standalone_respects_explicit_server_choice()
    test_standalone_skipped_for_subcommands_without_the_flag()
    test_standalone_reaches_herdr_pane_args()
    test_lifecycle_order_and_arguments()
    print("bootstrap checks passed")
