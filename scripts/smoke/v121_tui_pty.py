#!/usr/bin/env python3
"""Bounded black-box PTY qualification for the v1.2.1 thin TUI client.

This helper intentionally uses only the Python standard library. It keeps a
bounded terminal capture in memory only for assertions, discards daemon output,
and writes a content-free PASS manifest suitable for release evidence.
"""

from __future__ import annotations

import argparse
import datetime as dt
import errno
import fcntl
import hashlib
import json
import os
import pathlib
import pty
import re
import select
import secrets
import signal
import struct
import subprocess
import sys
import termios
import time
import urllib.error
import urllib.parse
import urllib.request


ALT_ENTER = b"\x1b[?1049h"
ALT_LEAVE = b"\x1b[?1049l"
CURSOR_UP = b"\x1b[1A"
ANSI_RE = re.compile(
    rb"(?:\x1B\][^\x07\x1b]*(?:\x07|\x1B\\)|\x1B[@-_][0-?]*[ -/]*[@-~])"
)
HELP_MARKER = re.compile(r"Available slash commands:", re.IGNORECASE)
UNKNOWN_COMMAND_MARKER = re.compile(
    r"Unknown slash command\. Type /help for available commands\.",
    re.IGNORECASE,
)
CUSTODY_FRAME_LIMIT = 32
CUSTODY_FULL_MARKER = re.compile(
    r"Input custody is full; terminal input is paused until a receipt finishes\.",
    re.IGNORECASE,
)
TERMINAL_ERROR_LINE = re.compile(r"\[error\][ ]+([^\r\n]+)", re.IGNORECASE)
AMBIGUOUS_RECEIPT_PROMPT = re.compile(
    r"The daemon connection closed with ([0-9]{1,2}) unresolved input receipt\(s\):"
    r"[^\r\n]{1,512}\r?\nReconnect once to reconcile them without creating new "
    r"receipts\? \[y/N\] ",
    re.IGNORECASE,
)
ATTACHED_MARKER = re.compile(r"Allbert TUI - daemon attached", re.IGNORECASE)
ATTACH_DEGRADED_MARKER = re.compile(
    r"(?:\*\* \(Mix\)\s+)?TUI client could not continue: :[a-z][a-z0-9_]{1,31}"
    r"(?=\r?\n|\Z)",
    re.IGNORECASE,
)


class QualificationFailure(RuntimeError):
    """A safe, content-free qualification failure."""


def reject_duplicate_json_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def safe_text(raw: bytes) -> str:
    return ANSI_RE.sub(b"", raw).decode("utf-8", errors="replace")


def restore_signal_mask(mask: set[signal.Signals]):
    """Build the child-only hook that reverses the parent's acquisition mask."""

    def restore() -> None:
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)

    return restore


def line_bounded_pattern(pattern: str) -> re.Pattern[str]:
    """Require a prompt to occupy a complete terminal line, never an input echo."""

    return re.compile(
        rf"(?:\A|(?<=[\r\n]))(?:{pattern})(?=\Z|[\r\n])",
        re.IGNORECASE | re.MULTILINE,
    )


def write_json_no_clobber(path: pathlib.Path, payload: object) -> None:
    """Atomically publish one private JSON receipt without following a final symlink."""

    if not path.parent.is_dir():
        raise QualificationFailure("evidence parent is unavailable")

    temporary = path.parent / f".{path.name}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
    descriptor: int | None = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(temporary, flags, 0o600)
        encoded = (json.dumps(payload, sort_keys=True, indent=2) + "\n").encode("utf-8")
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = None
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.link(temporary, path, follow_symlinks=False)
    except FileExistsError as error:
        raise QualificationFailure("fresh evidence path is already occupied") from error
    except OSError as error:
        raise QualificationFailure("atomic evidence publication failed") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def tree_fingerprint(root: pathlib.Path) -> str:
    """Digest names, kinds, symlink targets, and regular-file bytes."""

    digest = hashlib.sha256()
    if not root.exists():
        return digest.hexdigest()

    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        rel = path.relative_to(root).as_posix().encode()
        if path.is_symlink():
            digest.update(b"L\0" + rel + b"\0" + os.readlink(path).encode() + b"\0")
        elif path.is_dir():
            digest.update(b"D\0" + rel + b"\0")
        elif path.is_file():
            digest.update(b"F\0" + rel + b"\0")
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(64 * 1024), b""):
                    digest.update(chunk)
        else:
            digest.update(b"O\0" + rel + b"\0")
    return digest.hexdigest()


class PtyClient:
    def __init__(
        self,
        command: list[str],
        env: dict[str, str],
        max_capture_bytes: int,
        child_signal_mask: set[signal.Signals] | None = None,
    ) -> None:
        self.command = command
        self.env = env
        self.max_capture_bytes = max_capture_bytes
        self.master_fd = -1
        self.slave_fd = -1
        self.process: subprocess.Popen[bytes] | None = None
        self.before: list[object] | None = None
        self.after: list[object] | None = None
        self.slave_closed = False
        self.pty_eof = False
        self.closed = False
        self.raw = bytearray()

        try:
            self.master_fd, self.slave_fd = pty.openpty()
            self._set_size(100, 30)
            self.before = termios.tcgetattr(self.slave_fd)
            slave_fd = self.slave_fd

            def make_controlling_terminal() -> None:
                os.setsid()
                fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
                if child_signal_mask is not None:
                    signal.pthread_sigmask(signal.SIG_SETMASK, child_signal_mask)

            self.process = subprocess.Popen(
                command,
                stdin=self.slave_fd,
                stdout=self.slave_fd,
                stderr=self.slave_fd,
                env=env,
                close_fds=True,
                preexec_fn=make_controlling_terminal,
            )
            os.set_blocking(self.master_fd, False)
        except BaseException:
            try:
                self.close()
            except Exception:
                pass
            raise

    def _set_size(self, columns: int, rows: int) -> None:
        packed = struct.pack("HHHH", rows, columns, 0, 0)
        fcntl.ioctl(self.master_fd, termios.TIOCSWINSZ, packed)

    def resize(self, columns: int, rows: int) -> None:
        self._set_size(columns, rows)
        try:
            os.killpg(self.process.pid, signal.SIGWINCH)
        except ProcessLookupError:
            pass

    def send(self, payload: bytes) -> None:
        try:
            os.write(self.master_fd, payload)
        except OSError as error:
            raise QualificationFailure("client input channel closed early") from error

    def _read_available(self, timeout: float) -> None:
        if self.pty_eof:
            return
        readable, _, _ = select.select([self.master_fd], [], [], max(timeout, 0.0))
        if not readable:
            return
        try:
            chunk = os.read(self.master_fd, 64 * 1024)
        except BlockingIOError:
            return
        except OSError as error:
            if error.errno == errno.EIO:
                self.pty_eof = True
                return
            raise QualificationFailure("PTY read failed") from error
        if chunk:
            self.raw.extend(chunk)
            if len(self.raw) > self.max_capture_bytes:
                raise QualificationFailure("bounded terminal capture exceeded")
        else:
            self.pty_eof = True

    def wait_for(self, pattern: re.Pattern[str], timeout: float, start: int = 0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if pattern.search(safe_text(bytes(self.raw[start:]))):
                return
            self._read_available(min(0.1, deadline - time.monotonic()))
            if self.process.poll() is not None:
                self._drain_after_exit()
                if pattern.search(safe_text(bytes(self.raw[start:]))):
                    return
                break
        raise QualificationFailure("expected bounded terminal state was not observed")

    def wait_for_count(self, pattern: re.Pattern[str], count: int, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        observed_count = 0
        while time.monotonic() < deadline:
            observed_count = len(pattern.findall(safe_text(bytes(self.raw))))
            if observed_count >= count:
                return
            self._read_available(min(0.1, deadline - time.monotonic()))
            if self.process.poll() is not None:
                self._drain_after_exit()
                observed_count = len(pattern.findall(safe_text(bytes(self.raw))))
                if observed_count >= count:
                    return
                break
        returncode = self.process.poll()
        raise QualificationFailure(
            "expected bounded terminal completion was not observed "
            f"(observed={observed_count}, expected={count}, "
            f"client_exited={str(returncode is not None).lower()}, "
            f"returncode={returncode if returncode is not None else 'running'})"
        )

    def wait_for_count_followed_by(
        self,
        marker: re.Pattern[str],
        count: int,
        following: re.Pattern[str],
        timeout: float,
    ) -> None:
        """Wait for the counted daemon marker and a later line-bounded ready prompt."""

        deadline = time.monotonic() + timeout
        observed_count = 0
        prompt_after_count = False
        while time.monotonic() < deadline:
            text = safe_text(bytes(self.raw))
            matches = list(marker.finditer(text))
            observed_count = len(matches)
            prompt_after_count = observed_count >= count and bool(
                following.search(text, matches[count - 1].end())
            )
            if prompt_after_count:
                return
            self._read_available(min(0.1, deadline - time.monotonic()))
            if self.process.poll() is not None:
                self._drain_after_exit()
                text = safe_text(bytes(self.raw))
                matches = list(marker.finditer(text))
                observed_count = len(matches)
                prompt_after_count = observed_count >= count and bool(
                    following.search(text, matches[count - 1].end())
                )
                if prompt_after_count:
                    return
                break
        raise QualificationFailure(
            "counted terminal completion was not followed by a ready prompt "
            f"(observed={observed_count}, expected={count}, "
            f"prompt_after_count={str(prompt_after_count).lower()})"
        )

    def drain_for(self, duration: float) -> None:
        deadline = time.monotonic() + max(duration, 0.0)
        while time.monotonic() < deadline and self.process.poll() is None:
            self._read_available(min(0.05, deadline - time.monotonic()))

    def _drain_after_exit(self) -> None:
        if self.after is None:
            for descriptor in (self.slave_fd, self.master_fd):
                try:
                    self.after = termios.tcgetattr(descriptor)
                    break
                except (OSError, termios.error):
                    continue
            if self.after is None:
                raise QualificationFailure("PTY attributes were unavailable after client exit")
        if not self.slave_closed:
            os.close(self.slave_fd)
            self.slave_closed = True
            self.slave_fd = -1
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline and not self.pty_eof:
            self._read_available(0.05)
        if not self.pty_eof:
            raise QualificationFailure("PTY did not reach EOF after client exit")

    def wait_exit(self, timeout: float) -> int:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self._read_available(0.05)
            result = self.process.poll()
            if result is not None:
                self._drain_after_exit()
                return result
        raise QualificationFailure("TUI client did not exit within the bounded deadline")

    def assert_terminal_restored(self) -> None:
        if self.after is None or self.after != self.before:
            raise QualificationFailure("TUI client did not restore the exact PTY attributes")
        enter_count = self.raw.count(ALT_ENTER)
        leave_count = self.raw.count(ALT_LEAVE)
        if enter_count == 0 or enter_count != leave_count:
            raise QualificationFailure("alternate-screen enter/leave pair was incomplete")
        if self.raw.rfind(ALT_LEAVE) < self.raw.rfind(ALT_ENTER):
            raise QualificationFailure("final alternate-screen leave did not follow final enter")

    def assert_never_entered_terminal_mode(self) -> None:
        if self.after is None or self.after != self.before:
            raise QualificationFailure("rejected TUI launch changed terminal attributes")
        if ALT_ENTER in self.raw or ALT_LEAVE in self.raw:
            raise QualificationFailure("rejected TUI launch emitted alternate-screen control")

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        cleanup_error: Exception | None = None
        process = self.process
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except Exception as error:
                cleanup_error = error
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except Exception as error:
                    if cleanup_error is None:
                        cleanup_error = error
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired as error:
                    if cleanup_error is None:
                        cleanup_error = error
        if process is not None and process.poll() is not None and self.after is None:
            try:
                self._drain_after_exit()
            except (OSError, termios.error, QualificationFailure):
                pass
        if self.master_fd >= 0:
            try:
                os.close(self.master_fd)
            except OSError as error:
                if cleanup_error is None:
                    cleanup_error = error
            self.master_fd = -1
        if not self.slave_closed and self.slave_fd >= 0:
            try:
                os.close(self.slave_fd)
            except OSError as error:
                if cleanup_error is None:
                    cleanup_error = error
            self.slave_closed = True
            self.slave_fd = -1
        if cleanup_error is not None:
            raise QualificationFailure("TUI client cleanup did not complete") from cleanup_error


class Qualification:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.home = pathlib.Path(args.home).resolve()
        self.home.mkdir(parents=True, exist_ok=True)
        self.work = pathlib.Path(args.work).resolve()
        self.work.mkdir(parents=True, exist_ok=True)
        self.daemon: subprocess.Popen[bytes] | None = None
        self.daemon_suspended = False
        self.provider_processes: list[subprocess.Popen[bytes]] = []
        self.clients: list[PtyClient] = []
        self.results: list[dict[str, str]] = []
        self.provider_receipt_manifest: dict[str, object] | None = None
        self.http_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.prompt = line_bounded_pattern(args.prompt_regex)
        self.no_daemon = re.compile(args.no_daemon_regex, re.IGNORECASE | re.DOTALL)
        self.occupied = re.compile(args.occupied_regex, re.IGNORECASE | re.DOTALL)
        self.daemon_loss = re.compile(args.daemon_loss_regex, re.IGNORECASE | re.DOTALL)
        allowed_env = (
            "PATH",
            "SHELL",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "TERM",
            "MIX_ENV",
            "MIX_HOME",
            "SSL_CERT_FILE",
            "SSL_CERT_DIR",
        )
        self.env = {
            name: os.environ[name]
            for name in allowed_env
            if isinstance(os.environ.get(name), str) and os.environ[name] != ""
        }
        host_home = self.work / "host-home"
        host_home.mkdir(mode=0o700, exist_ok=True)
        child_tmp = self.work / "child-tmp"
        child_tmp.mkdir(mode=0o700, exist_ok=True)
        self.env.update(
            {
                "ALLBERT_HOME": str(self.home),
                "HOME": str(host_home),
                "TMPDIR": str(child_tmp),
                "PORT": str(args.port),
                "TERM": self.env.get("TERM") or "xterm-256color",
                "COLUMNS": "100",
                "LINES": "30",
            }
        )
        inherited_erl_aflags = os.environ.get("ERL_AFLAGS")
        self.tui_erl_aflags = (
            f"{inherited_erl_aflags} +Bc" if inherited_erl_aflags else "+Bc"
        )
        self.provider: dict[str, str] | None = None
        if args.provider_required:
            self.provider = self._provider_config()
        else:
            os.environ.pop("ALLBERT_V121_PROVIDER_CONFIG", None)
            os.environ.pop("ALLBERT_V121_PROVIDER_MODEL", None)
            self.env.pop("ALLBERT_V121_PROVIDER_CONFIG", None)
            self.env.pop("ALLBERT_V121_PROVIDER_MODEL", None)
            for env_name in (
                "OPENAI_API_KEY",
                "ANTHROPIC_API_KEY",
                "OPENROUTER_API_KEY",
                "GOOGLE_API_KEY",
                "GEMINI_API_KEY",
            ):
                self.env.pop(env_name, None)

    def _provider_config(self) -> dict[str, str]:
        raw = os.environ.get("ALLBERT_V121_PROVIDER_CONFIG")
        model = os.environ.get("ALLBERT_V121_PROVIDER_MODEL")
        os.environ.pop("ALLBERT_V121_PROVIDER_CONFIG", None)
        os.environ.pop("ALLBERT_V121_PROVIDER_MODEL", None)
        if not isinstance(raw, str) or not isinstance(model, str):
            raise QualificationFailure("configured-provider inputs are absent")
        try:
            raw_bytes = raw.encode("utf-8")
            model_bytes = model.encode("utf-8")
        except UnicodeEncodeError as error:
            raise QualificationFailure("configured-provider inputs are not UTF-8") from error
        if len(raw_bytes) > 16 * 1024:
            raise QualificationFailure("configured-provider JSON exceeds bounds")
        try:
            config = json.loads(raw, object_pairs_hook=reject_duplicate_json_keys)
        except (json.JSONDecodeError, UnicodeError, ValueError) as error:
            raise QualificationFailure("configured-provider JSON is invalid") from error
        if not isinstance(config, dict):
            raise QualificationFailure("configured-provider JSON must be an object")
        required = {"provider", "profile", "api_key"}
        allowed = required | {"base_url"}
        if set(config) - allowed or not required.issubset(config):
            raise QualificationFailure("configured-provider JSON keys violate the closed schema")
        if not all(isinstance(config[key], str) for key in required):
            raise QualificationFailure("configured-provider fields must be strings")

        provider = config["provider"]
        env_names = {
            "openai": "OPENAI_API_KEY",
            "anthropic": "ANTHROPIC_API_KEY",
            "openrouter": "OPENROUTER_API_KEY",
            "gemini": "GEMINI_API_KEY",
        }
        if provider not in env_names:
            raise QualificationFailure("configured-provider name is not allowlisted")
        profile = config["profile"]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", profile):
            raise QualificationFailure("configured-provider profile is invalid")
        api_key = config["api_key"]
        try:
            api_key_bytes = api_key.encode("utf-8")
        except UnicodeEncodeError as error:
            raise QualificationFailure("configured-provider credential is not UTF-8") from error
        if not (1 <= len(api_key_bytes) <= 8192) or any(
            character in api_key for character in ("\x00", "\r", "\n")
        ):
            raise QualificationFailure("configured-provider credential violates bounds")
        if not (1 <= len(model_bytes) <= 200) or any(
            character in model for character in ("\x00", "\r", "\n")
        ):
            raise QualificationFailure("configured-provider model violates bounds")

        base_url = config.get("base_url")
        if base_url is not None:
            if (
                not isinstance(base_url, str)
                or not (1 <= len(base_url) <= 2048)
                or any(
                    ord(character) <= 0x20 or ord(character) == 0x7F
                    for character in base_url
                )
            ):
                raise QualificationFailure("configured-provider base URL violates bounds")
            try:
                parsed = urllib.parse.urlsplit(base_url)
                hostname = parsed.hostname
                _port = parsed.port
            except ValueError as error:
                raise QualificationFailure("configured-provider base URL is invalid") from error
            loopback = hostname in {"localhost", "127.0.0.1", "::1"}
            if (
                parsed.username is not None
                or parsed.password is not None
                or parsed.query
                or parsed.fragment
                or not hostname
                or not (parsed.scheme == "https" or (parsed.scheme == "http" and loopback))
            ):
                raise QualificationFailure("configured-provider base URL is not HTTPS or loopback")

        for env_name in (*env_names.values(), "GOOGLE_API_KEY"):
            self.env.pop(env_name, None)
        self.env[env_names[provider]] = api_key
        return {
            "provider": provider,
            "profile": profile,
            "model": model,
            **({"base_url": base_url} if base_url is not None else {}),
        }

    def _product_cli(self, arguments: list[str], capture: bool = False) -> bytes:
        process: subprocess.Popen[bytes] | None = None
        trapped = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, trapped)
        try:
            try:
                process = subprocess.Popen(
                    [self.args.tui_bin, *arguments],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                    stderr=subprocess.STDOUT,
                    env=self.env,
                    start_new_session=True,
                    preexec_fn=restore_signal_mask(previous_mask),
                )
            except OSError as error:
                raise QualificationFailure(
                    "configured-provider product command failed"
                ) from error
            self.provider_processes.append(process)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

        output = bytearray()
        try:
            deadline = time.monotonic() + 90
            if process.stdout is not None:
                os.set_blocking(process.stdout.fileno(), False)
            while process.poll() is None and time.monotonic() < deadline:
                if process.stdout is not None:
                    readable, _, _ = select.select([process.stdout], [], [], 0.1)
                    if readable:
                        chunk = process.stdout.read(16 * 1024)
                        if chunk:
                            output.extend(chunk)
                            if len(output) > 64 * 1024:
                                self._stop_process_group(process, term_timeout=2.0)
                                raise QualificationFailure(
                                    "configured-provider command output exceeded bounds"
                                )
                else:
                    time.sleep(0.05)
            if process.poll() is None:
                self._stop_process_group(process, term_timeout=2.0)
                raise QualificationFailure("configured-provider product command timed out")
            if process.stdout is not None:
                while True:
                    try:
                        chunk = process.stdout.read(16 * 1024)
                    except BlockingIOError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
                    if len(output) > 64 * 1024:
                        raise QualificationFailure(
                            "configured-provider command output exceeded bounds"
                        )
            if process.returncode != 0:
                raise QualificationFailure(
                    "configured-provider product command returned non-zero"
                )
            return bytes(output) if capture else b""
        finally:
            if process.poll() is not None:
                if process.stdout is not None:
                    process.stdout.close()
                if process in self.provider_processes:
                    self.provider_processes.remove(process)

    def configure_provider(self) -> None:
        if self.provider is None:
            return
        provider = self.provider["provider"]
        profile = self.provider["profile"]
        output = self._product_cli(
            ["admin", "settings", "get", f"model_profiles.{profile}.provider"],
            capture=True,
        )
        text = output.decode("utf-8", errors="replace")
        if not re.search(
            rf"model_profiles\.{re.escape(profile)}\.provider[^\r\n]*\b{re.escape(provider)}\b",
            text,
            re.IGNORECASE,
        ):
            raise QualificationFailure("configured-provider profile/provider binding does not match")

        if "base_url" in self.provider:
            self._product_cli(
                [
                    "admin",
                    "settings",
                    "set",
                    f"providers.{provider}.base_url",
                    self.provider["base_url"],
                ]
            )
        self._product_cli(
            [
                "admin",
                "settings",
                "set",
                f"model_profiles.{profile}.model",
                self.provider["model"],
            ]
        )
        self._product_cli(
            ["admin", "models", "use", profile, "--enable-assist"]
        )
        for key, value in (
            ("intent.direct_answer_model_profile", profile),
            ("intent.direct_answer_model_enabled", "true"),
        ):
            self._product_cli(["admin", "settings", "set", key, value])

        active = self._product_cli(
            ["admin", "models", "list"], capture=True
        ).decode("utf-8", errors="replace").splitlines()
        if f"Active model profile: {profile}" not in active:
            raise QualificationFailure("configured-provider profile did not become active")
        if "Model-assisted intent: true" not in active:
            raise QualificationFailure("configured-provider model assist was not enabled")

        doctor = self._product_cli(
            ["admin", "models", "doctor", profile], capture=True
        ).decode("utf-8", errors="replace")
        if "credential_ok=true" not in doctor:
            raise QualificationFailure("configured-provider credential preflight failed")
        if not re.search(r"endpoint_ok=(?:ok|true)", doctor):
            raise QualificationFailure("configured-provider endpoint preflight failed")
        if "model_available=true" not in doctor:
            raise QualificationFailure("configured-provider model preflight failed")

        nonce = secrets.token_hex(16)
        self.args.provider_reply = f"V121_PROVIDER_OK_{nonce}"
        self.args.provider_prompt = (
            "Reply with exactly the four underscore-joined tokens V121, PROVIDER, "
            f"OK, and {nonce}, with no other text."
        )

    def record(self, case: str) -> None:
        self.results.append({"id": case, "status": "pass"})
        print(f"v121-tui-pty:{case} PASS", flush=True)

    def new_client(self) -> PtyClient:
        client_env = dict(self.env)
        client_env["ERL_AFLAGS"] = self.tui_erl_aflags
        client_env.pop("ALLBERT_HOLD_WRITER_LOCK", None)
        client_env.pop("PHX_SERVER", None)
        for env_name in (
            "OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
            "OPENROUTER_API_KEY",
            "GOOGLE_API_KEY",
            "GEMINI_API_KEY",
        ):
            client_env.pop(env_name, None)
        trapped = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, trapped)
        try:
            client = PtyClient(
                self.args.tui_command,
                client_env,
                self.args.max_capture_bytes,
                child_signal_mask=previous_mask,
            )
            self.clients.append(client)
            return client
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

    def start_daemon(self, degraded: bool = False) -> None:
        daemon_env = dict(self.env)
        daemon_env["PHX_SERVER"] = "1"
        daemon_env["ALLBERT_HOLD_WRITER_LOCK"] = "1"
        trapped = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, trapped)
        try:
            try:
                daemon = subprocess.Popen(
                    self.args.daemon_command,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.STDOUT,
                    env=daemon_env,
                    start_new_session=True,
                    preexec_fn=restore_signal_mask(previous_mask),
                )
            except OSError as error:
                raise QualificationFailure("daemon process could not start") from error
            self.daemon = daemon
            self.daemon_suspended = False
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        if degraded:
            self.wait_degraded_health()
        else:
            self.wait_health()

    def _stop_process_group(
        self,
        process: subprocess.Popen[bytes],
        *,
        term_timeout: float,
        resume: bool = False,
    ) -> None:
        if process.poll() is not None:
            return
        if resume:
            try:
                os.killpg(process.pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=term_timeout)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired as error:
            raise QualificationFailure(
                "tracked child did not exit within the cleanup deadline"
            ) from error

    def stop_daemon(self) -> None:
        if self.daemon is None:
            return
        self._stop_process_group(
            self.daemon,
            term_timeout=10.0,
            resume=self.daemon_suspended,
        )
        self.daemon = None
        self.daemon_suspended = False

    def suspend_daemon(self) -> None:
        if self.daemon is None or self.daemon.poll() is not None:
            raise QualificationFailure("daemon was unavailable before pressure suspension")
        try:
            os.killpg(self.daemon.pid, signal.SIGSTOP)
        except ProcessLookupError as error:
            raise QualificationFailure("daemon disappeared before pressure suspension") from error
        self.daemon_suspended = True

        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            if self.daemon.poll() is not None:
                raise QualificationFailure("daemon exited during pressure suspension")
            if not self.health_ok():
                return
            time.sleep(0.05)
        raise QualificationFailure("daemon did not enter the bounded pressure suspension")

    def resume_daemon(self) -> None:
        if not self.daemon_suspended:
            return
        if self.daemon is None or self.daemon.poll() is not None:
            raise QualificationFailure("daemon exited before pressure resume")
        try:
            os.killpg(self.daemon.pid, signal.SIGCONT)
        except ProcessLookupError as error:
            raise QualificationFailure("daemon disappeared before pressure resume") from error
        self.daemon_suspended = False
        self.wait_health()

    def http_get(self, path: str, timeout: float = 1.0) -> tuple[int, bytes]:
        try:
            with self.http_opener.open(
                f"http://127.0.0.1:{self.args.port}{path}", timeout=timeout
            ) as response:
                return response.status, response.read(64 * 1024)
        except urllib.error.HTTPError as error:
            return error.code, error.read(64 * 1024)
        except (urllib.error.URLError, TimeoutError):
            return 0, b""

    def health_ok(self) -> bool:
        status, body = self.http_get("/health")
        return status == 200 and b'"status":"ok"' in body.replace(b" ", b"")

    def degraded_health_ok(self) -> bool:
        status, body = self.http_get("/health")
        if status != 503:
            return False
        try:
            payload = json.loads(body)
        except (json.JSONDecodeError, UnicodeError):
            return False
        return (
            payload.get("status") == "degraded"
            and isinstance(payload.get("attach"), dict)
            and payload["attach"].get("status") == "degraded"
        )

    def web_ok(self) -> bool:
        # The first rendered page resolves Settings through the action spine and
        # can legitimately take longer than the narrow health probe on a cold
        # source checkout. Keep this bounded without treating startup work as a
        # Web outage.
        status, _body = self.http_get("/", timeout=5.0)
        return status == 200

    def wait_degraded_web(self) -> None:
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            if self.daemon is not None and self.daemon.poll() is not None:
                raise QualificationFailure(
                    "degraded daemon exited before the Web route became ready"
                )
            if self.degraded_health_ok() and self.web_ok():
                return
            time.sleep(0.1)
        raise QualificationFailure(
            "Web route did not become ready while Attach remained degraded"
        )

    def wait_health(self) -> None:
        deadline = time.monotonic() + self.args.startup_timeout
        while time.monotonic() < deadline:
            if self.daemon is not None and self.daemon.poll() is not None:
                raise QualificationFailure("daemon exited before health became ready")
            if self.health_ok():
                return
            time.sleep(0.25)
        raise QualificationFailure("daemon health did not become ready within the deadline")

    def wait_degraded_health(self) -> None:
        deadline = time.monotonic() + self.args.startup_timeout
        while time.monotonic() < deadline:
            if self.daemon is not None and self.daemon.poll() is not None:
                raise QualificationFailure("degraded daemon exited before Web became ready")
            if self.degraded_health_ok():
                return
            time.sleep(0.25)
        raise QualificationFailure("Attach-degraded Web did not become ready within the deadline")

    def assert_health(self) -> None:
        if not self.health_ok():
            raise QualificationFailure("daemon/Web health regressed during TUI qualification")

    def open_client(self) -> PtyClient:
        client = self.new_client()
        try:
            client.wait_for(self.prompt, self.args.client_timeout)
            self.assert_health()
            return client
        except BaseException:
            try:
                client.close()
            except Exception:
                # Preserve the acquisition failure; top-level cleanup gets one
                # more idempotent chance to release every recorded client.
                pass
            raise

    def normal_quit(self, client: PtyClient) -> None:
        client.send(b"/quit\n")
        result = client.wait_exit(self.args.client_timeout)
        if result != 0:
            raise QualificationFailure("normal TUI detach returned non-zero")
        client.assert_terminal_restored()

    def case_no_daemon(self) -> None:
        before = tree_fingerprint(self.home)
        client = self.new_client()
        try:
            result = client.wait_exit(self.args.client_timeout)
            if result == 0:
                raise QualificationFailure("no-daemon launch returned success")
            if not self.no_daemon.search(safe_text(bytes(client.raw))):
                raise QualificationFailure("no-daemon repair guidance was absent")
            client.assert_never_entered_terminal_mode()
        finally:
            client.close()
        after = tree_fingerprint(self.home)
        if before != after:
            raise QualificationFailure("no-daemon launch mutated the disposable Allbert Home")
        self.record("no-daemon-no-writer")

    def case_attach_degraded(self) -> None:
        socket_path = self.home / "runtime" / "attach.sock"
        socket_path.parent.mkdir(parents=True, exist_ok=True)
        if socket_path.is_symlink() or socket_path.is_file():
            socket_path.unlink()
        elif socket_path.exists():
            raise QualificationFailure("Attach degradation fixture path is unexpectedly occupied")
        socket_path.mkdir(mode=0o700)

        self.start_daemon(degraded=True)
        client = self.new_client()
        try:
            result = client.wait_exit(self.args.client_timeout)
            if result == 0:
                raise QualificationFailure("Attach-degraded TUI returned success")
            if not ATTACH_DEGRADED_MARKER.search(safe_text(bytes(client.raw))):
                raise QualificationFailure(
                    "Attach-degraded TUI lacked its bounded rejection diagnostic"
                )
            client.assert_never_entered_terminal_mode()
            self.wait_degraded_web()
        finally:
            client.close()
            self.stop_daemon()

        try:
            socket_path.rmdir()
        except OSError as error:
            raise QualificationFailure("Attach degradation fixture did not cleanly release") from error
        self.start_daemon()
        self.assert_health()
        self.record("attach-degraded-web-available")

    def case_occupied(self) -> None:
        first = self.open_client()
        second = self.new_client()
        try:
            result = second.wait_exit(self.args.client_timeout)
            if result == 0:
                raise QualificationFailure("occupied-session launch returned success")
            if not self.occupied.search(safe_text(bytes(second.raw))):
                raise QualificationFailure("occupied-session diagnostic was absent")
            second.assert_never_entered_terminal_mode()
            self.normal_quit(first)
        finally:
            second.close()
            first.close()
        self.assert_health()
        self.record("occupied-session-health")

    def case_resize(self) -> None:
        client = self.open_client()
        try:
            # Hold every distinct size beyond the client's 250 ms poll interval
            # so this black-box row really crosses the frozen 32-frame window;
            # a burst of ioctl calls would otherwise coalesce before observation.
            for index in range(38):
                client.resize(80 + (index % 7) * 9, 20 + (index % 5) * 3)
                time.sleep(0.35)

            # Establish an identical wide-command control. Any cursor-up output
            # shared by ordinary live-region redraw is captured in this baseline.
            client.resize(120, 40)
            time.sleep(0.6)
            client.drain_for(0.2)
            wide_start = len(client.raw)
            help_count = len(HELP_MARKER.findall(safe_text(bytes(client.raw))))
            client.send(b"/help\n")
            client.wait_for_count_followed_by(
                HELP_MARKER,
                help_count + 1,
                self.prompt,
                self.args.client_timeout,
            )
            client.drain_for(0.2)
            wide_cursor_ups = bytes(client.raw[wide_start:]).count(CURSOR_UP)

            # Repeat the same command narrow enough that clearing the submitted
            # prompt must move upward through at least two extra owned wrapped
            # rows. Only a resize-aware client produces this differential.
            client.resize(10, 20)
            time.sleep(0.6)
            client.drain_for(0.2)
            narrow_start = len(client.raw)
            help_count = len(HELP_MARKER.findall(safe_text(bytes(client.raw))))
            client.send(b"/help\n")
            client.wait_for_count_followed_by(
                HELP_MARKER,
                help_count + 1,
                self.prompt,
                self.args.client_timeout,
            )
            client.drain_for(0.2)
            narrow_cursor_ups = bytes(client.raw[narrow_start:]).count(CURSOR_UP)
            if narrow_cursor_ups < wide_cursor_ups + 2:
                raise QualificationFailure("PTY resize lacked a wide-to-narrow redraw differential")
            self.normal_quit(client)
        finally:
            client.close()
        self.assert_health()
        self.record("resize-terminal-restore")

    def case_pressure(self) -> None:
        client = self.open_client()
        suspended = False
        try:
            start = len(client.raw)
            help_count = len(HELP_MARKER.findall(safe_text(bytes(client.raw))))
            unknown_count = len(
                UNKNOWN_COMMAND_MARKER.findall(safe_text(bytes(client.raw)))
            )
            self.suspend_daemon()
            suspended = True

            # Fill the frozen 32-frame client receipt window first and require
            # the custody-specific pause. This avoids accidentally qualifying
            # on the independently timed transport-pressure state.
            for _ in range(CUSTODY_FRAME_LIMIT):
                client.send(b"/help\n")
            client.wait_for(
                CUSTODY_FULL_MARKER,
                self.args.pressure_timeout,
                start=start,
            )
            custody_release_offset = len(client.raw)

            # Submit the 33rd line only after the driver is observably paused.
            # It can complete only if the paused PTY/input-driver path retains
            # it until a daemon receipt releases custody after resume.
            client.send(b"/v121-custody-probe\n")
            time.sleep(self.args.pressure_hold_seconds)
            self.resume_daemon()
            suspended = False
            client.wait_for(
                self.prompt,
                self.args.pressure_timeout,
                start=custody_release_offset,
            )
            expected_unknown_count = unknown_count + 1
            client.wait_for_count(
                UNKNOWN_COMMAND_MARKER,
                expected_unknown_count,
                self.args.pressure_timeout,
            )
            client.drain_for(1.0)
            completed_help_count = len(
                HELP_MARKER.findall(safe_text(bytes(client.raw)))
            )
            completed_unknown_count = len(
                UNKNOWN_COMMAND_MARKER.findall(safe_text(bytes(client.raw)))
            )
            pressure_text = safe_text(bytes(client.raw[start:]))
            terminal_errors = TERMINAL_ERROR_LINE.findall(pressure_text)
            if (
                completed_help_count - help_count != CUSTODY_FRAME_LIMIT
                or completed_unknown_count != expected_unknown_count
                or terminal_errors
            ):
                raise QualificationFailure("pressure replay completed an unexpected input count")
            self.normal_quit(client)
        finally:
            try:
                if suspended:
                    self.resume_daemon()
            finally:
                client.close()
        self.assert_health()

        # Re-enter the same real custody-full posture with a fresh client and
        # press Ctrl-C while terminal demand is paused. The first probe above
        # remains the strict 32+33 replay/count proof; this second probe proves
        # the raw terminal retains the control byte until receipt release lets
        # the client detach and restore the PTY exactly.
        interrupt_client = self.open_client()
        suspended = False
        try:
            start = len(interrupt_client.raw)
            attached_count = len(
                ATTACHED_MARKER.findall(safe_text(bytes(interrupt_client.raw)))
            )
            self.suspend_daemon()
            suspended = True
            for _ in range(CUSTODY_FRAME_LIMIT):
                interrupt_client.send(b"/help\n")
            interrupt_client.wait_for(
                CUSTODY_FULL_MARKER,
                self.args.pressure_timeout,
                start=start,
            )
            interrupt_client.send(b"\x03")
            time.sleep(self.args.pressure_hold_seconds)
            if interrupt_client.process.poll() is not None:
                raise QualificationFailure(
                    "custody-full Ctrl-C exited before receipt release"
                )
            self.resume_daemon()
            suspended = False
            interrupt_client.wait_for(
                AMBIGUOUS_RECEIPT_PROMPT,
                self.args.pressure_timeout,
                start=start,
            )
            pressure_exit_text = safe_text(bytes(interrupt_client.raw[start:]))
            unresolved = AMBIGUOUS_RECEIPT_PROMPT.findall(pressure_exit_text)
            if len(unresolved) != 1 or int(unresolved[0]) not in range(1, 33):
                raise QualificationFailure(
                    "custody-full Ctrl-C lacked one bounded ambiguous receipt count"
                )
            interrupt_client.send(b"n\n")
            result = interrupt_client.wait_exit(self.args.client_timeout)
            if result == 0:
                raise QualificationFailure(
                    "custody-full reconciliation unexpectedly returned success"
                )
            interrupt_client.assert_terminal_restored()
            completed_text = safe_text(bytes(interrupt_client.raw))
            if len(ATTACHED_MARKER.findall(completed_text)) != attached_count:
                raise QualificationFailure(
                    "custody-full reconciliation reattached after explicit decline"
                )
        finally:
            try:
                if suspended:
                    self.resume_daemon()
            finally:
                interrupt_client.close()
        self.assert_health()
        self.record("pressure-bounded-health")

    def case_control_exit(self, name: str, control: bytes) -> None:
        client = self.open_client()
        try:
            client.send(control)
            try:
                result = client.wait_exit(self.args.client_timeout)
            except QualificationFailure as error:
                raise QualificationFailure(
                    f"{name} client did not exit within the bounded deadline"
                ) from error
            if result != 0:
                raise QualificationFailure("handled control exit returned non-zero")
            client.assert_terminal_restored()
        finally:
            client.close()
        self.assert_health()
        self.record(name)

    def case_signal_exit(self, name: str, handled_signal: signal.Signals) -> None:
        client = self.open_client()
        try:
            os.killpg(client.process.pid, handled_signal)
            try:
                result = client.wait_exit(self.args.client_timeout)
            except QualificationFailure as error:
                raise QualificationFailure(
                    f"{name} client did not exit within the bounded deadline"
                ) from error
            if result != 0:
                raise QualificationFailure("handled signal exit returned non-zero")
            client.assert_terminal_restored()
        finally:
            client.close()
        self.assert_health()
        self.record(name)

    def case_daemon_loss_restart(self) -> None:
        client = self.open_client()
        try:
            self.stop_daemon()
            client.wait_for(self.daemon_loss, self.args.client_timeout)
            result = client.wait_exit(self.args.client_timeout)
            if result == 0:
                raise QualificationFailure("unexpected daemon loss returned success")
            client.assert_terminal_restored()
        finally:
            client.close()

        self.start_daemon()
        replacement = self.open_client()
        try:
            self.normal_quit(replacement)
        finally:
            replacement.close()
        self.assert_health()
        self.record("daemon-loss-restart-health")

    def case_provider(self) -> None:
        if self.args.provider_prompt is None:
            return
        client = self.open_client()
        try:
            start = len(client.raw)
            client.send(self.args.provider_prompt.encode("utf-8") + b"\n")
            client.wait_for(
                re.compile(re.escape(self.args.provider_reply)),
                self.args.provider_timeout,
                start=start,
            )
            client.wait_for_count_followed_by(
                re.compile(re.escape(self.args.provider_reply)),
                1,
                self.prompt,
                self.args.provider_timeout,
            )
            self.normal_quit(client)
        finally:
            client.close()
        self.assert_health()
        self.record("configured-provider-turn")
        receipt = {
            "schema": 1,
            "kind": "v121_tui_provider_receipt",
            "target": self.args.target,
            "subject": self.args.subject,
            "challenge_sha256": hashlib.sha256(
                self.args.provider_prompt.encode("utf-8")
            ).hexdigest(),
            "provider_profile_sha256": hashlib.sha256(
                (
                    self.provider["provider"]
                    + "\0"
                    + self.provider["profile"]
                ).encode("utf-8")
            ).hexdigest(),
            "model_sha256": hashlib.sha256(
                self.provider["model"].encode("utf-8")
            ).hexdigest(),
            "doctor": "pass",
            "turn_completion": "pass",
            "status": "pass",
            "raw_transcript_retained": False,
        }
        self.provider_receipt_manifest = receipt

    def run(self) -> None:
        release_before = (
            tree_fingerprint(pathlib.Path(self.args.release_root))
            if self.args.release_root
            else None
        )
        self.configure_provider()
        self.case_no_daemon()
        self.case_attach_degraded()
        self.record("daemon-health-ready")
        self.case_occupied()
        self.case_resize()
        self.case_pressure()
        self.case_control_exit("ctrl-c-terminal-restore", b"\x03")
        self.case_control_exit("eof-terminal-restore", b"\x04")
        self.case_signal_exit("sigterm-terminal-restore", signal.SIGTERM)
        self.case_signal_exit("sighup-terminal-restore", signal.SIGHUP)
        self.case_daemon_loss_restart()
        self.case_provider()
        if self.args.release_root:
            release_after = tree_fingerprint(pathlib.Path(self.args.release_root))
            if release_before != release_after:
                raise QualificationFailure("qualification mutated the extracted release root")
            self.record("release-root-immutable")

    def write_evidence(self) -> None:
        if self.provider_receipt_manifest is not None:
            provider_receipt = pathlib.Path(self.args.provider_receipt)
            write_json_no_clobber(provider_receipt, self.provider_receipt_manifest)

        manifest = {
            "schema": 1,
            "kind": "v121_tui_pty_qualification",
            "created_at": utc_now(),
            "mode": self.args.mode,
            "target": self.args.target,
            "subject": self.args.subject,
            "raw_transcript_retained": False,
            "cases": self.results,
        }
        evidence = pathlib.Path(self.args.evidence)
        write_json_no_clobber(evidence, manifest)
        print(f"v121-tui-pty:evidence staged={evidence}", flush=True)

    def close(self) -> None:
        cleanup_error: Exception | None = None
        for client in reversed(self.clients):
            try:
                client.close()
            except Exception as error:
                if cleanup_error is None:
                    cleanup_error = error
        try:
            self.stop_daemon()
        except Exception as error:
            if cleanup_error is None:
                cleanup_error = error
        for process in list(self.provider_processes):
            try:
                self._stop_process_group(process, term_timeout=2.0)
                if process.stdout is not None:
                    process.stdout.close()
                self.provider_processes.remove(process)
            except Exception as error:
                if cleanup_error is None:
                    cleanup_error = error
        if cleanup_error is not None:
            raise QualificationFailure("qualification cleanup did not complete") from cleanup_error


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("source", "artifact"), required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--home", required=True)
    parser.add_argument("--release-root")
    parser.add_argument("--work", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--subject", required=True)
    parser.add_argument("--provider-required", action="store_true")
    parser.add_argument("--provider-receipt")
    parser.add_argument("--provider-timeout", type=float, default=90.0)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--daemon-bin", required=True)
    parser.add_argument("--daemon-arg", action="append", default=[])
    parser.add_argument("--tui-bin", required=True)
    parser.add_argument("--tui-arg", action="append", default=[])
    parser.add_argument("--startup-timeout", type=float, default=90.0)
    parser.add_argument("--client-timeout", type=float, default=15.0)
    parser.add_argument("--pressure-timeout", type=float, default=90.0)
    parser.add_argument("--pressure-hold-seconds", type=float, default=1.0)
    parser.add_argument("--max-capture-bytes", type=int, default=8 * 1024 * 1024)
    parser.add_argument(
        "--prompt-regex", default=r"allbert(?::[^\r\n>]{1,64})?>[ ]?"
    )
    parser.add_argument(
        "--no-daemon-regex",
        default=r"(?:allbert serve.{0,160}(?:start|repair|service)|(?:daemon|service).{0,160}allbert serve)",
    )
    parser.add_argument(
        "--occupied-regex",
        default=r"(?:already.{0,48}attach|session.{0,48}already)",
    )
    parser.add_argument(
        "--daemon-loss-regex",
        default=r"(?:(?:daemon|connection).{0,80}(?:closed|lost|reset|unavailable)|socket.{0,48}closed)",
    )
    args = parser.parse_args()
    args.daemon_command = [args.daemon_bin, *args.daemon_arg]
    args.tui_command = [args.tui_bin, *args.tui_arg]
    args.provider_prompt = None
    args.provider_reply = None
    if args.provider_required and args.provider_receipt is None:
        parser.error("--provider-required also requires --provider-receipt")
    if not args.provider_required and args.provider_receipt is not None:
        parser.error("--provider-receipt requires --provider-required")
    if args.max_capture_bytes < 256 * 1024 or args.max_capture_bytes > 32 * 1024 * 1024:
        parser.error("--max-capture-bytes must be between 256 KiB and 32 MiB")
    if args.mode == "artifact" and (
        args.release_root is None or not pathlib.Path(args.release_root).is_dir()
    ):
        parser.error("artifact mode requires an existing --release-root")
    if args.mode == "source" and args.release_root is not None:
        parser.error("source mode must not receive --release-root")
    return args


def main() -> int:
    args = parse_args()
    qualification: Qualification | None = None
    exit_status = 0
    qualified = False
    shutdown = {"requested": False}
    trapped = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    previous_handlers = {handled: signal.getsignal(handled) for handled in trapped}

    def request_shutdown(signum: int, _frame: object) -> None:
        if shutdown["requested"]:
            return
        shutdown["requested"] = True
        name = signal.Signals(signum).name
        raise QualificationFailure(f"qualification interrupted by {name}")

    for handled in trapped:
        signal.signal(handled, request_shutdown)

    try:
        qualification = Qualification(args)
        qualification.run()
        qualified = True
    except QualificationFailure as error:
        print(f"v121-tui-pty:FAIL {error}", file=sys.stderr)
        print(
            "Raw terminal/daemon output was not copied into release evidence; "
            "use a deliberate non-provider local rerun for private diagnostics if needed.",
            file=sys.stderr,
        )
        exit_status = 1
    finally:
        for handled in trapped:
            signal.signal(handled, signal.SIG_IGN)
        try:
            try:
                if qualification is not None:
                    qualification.close()
            except QualificationFailure as error:
                print(f"v121-tui-pty:FAIL cleanup: {error}", file=sys.stderr)
                exit_status = 1
            if qualified and exit_status == 0 and qualification is not None:
                try:
                    qualification.write_evidence()
                except QualificationFailure as error:
                    print(f"v121-tui-pty:FAIL evidence: {error}", file=sys.stderr)
                    exit_status = 1
        finally:
            for handled, previous in previous_handlers.items():
                signal.signal(handled, previous)
    return exit_status


if __name__ == "__main__":
    raise SystemExit(main())
