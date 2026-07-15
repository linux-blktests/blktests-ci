#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

"""Redeploy a new blktests-ci version onto an already-provisioned cluster.

Run this from a workstation that has pulled the latest changes and has the
Ansible variables and secrets in place (``variables.yaml``, ``secrets.enc`` and
``k8s-inventory.yaml``). The target cluster is chosen by the ``kubeconfig`` value
in ``variables.yaml`` (or ``--kubeconfig``); that path is exported for this
script's own ``kubectl``/``helm`` calls and for the ansible-playbook runs, so a
staging and a prod worktree each drive their own cluster. It performs a redeploy
in two steps:

  1. Re-run ``playbooks/install-k8s-requirements.yaml`` to refresh the
     cluster-wide components (longhorn, KubeVirt, registry, logging, mitmproxy,
     CI binary cache, kpd, physical-node config).
  2. Redeploy every runner scale set that already exists on the cluster, with
     no manual configuration: the runner name and the GitHub/GitLab config URL
     are read back from the cluster and the existing auth secret is reused.

Existing runner scale sets are discovered from the installed Helm releases
(``arc-vm-*`` for GitHub ARC, ``gitlab-runner-*`` for GitLab), never from bare
namespaces, so orphaned/auxiliary namespaces are ignored.

Before redeploying, active runs are terminated and no new job is accepted while
the redeploy is in flight: every discovered scale set is ``helm uninstall``ed
first (which removes the ARC listener / GitLab runner manager so nothing pulls
new work), then the KubeVirt VMs those jobs spawned are deleted. The scale sets
are recreated only at the very end, which is what lifts the freeze. This runs
before step 1 as well, so KubeVirt/longhorn are never upgraded underneath a
live VM.

Before anything is torn down, an overview of the currently deployed scale sets
(name, URL and the exact by-hand redeploy command for each) is printed and
written to a git-ignored manifest file. Each run writes its own timestamped
file (``redeploy-scale-sets-<timestamp>.log``) so manifests never overwrite one
another. If a redeploy fails hard (say the SSH agent had no key when
install-k8s-requirements ran), pass that manifest back with ``--from-log FILE``
to reload exactly those scale sets and redeploy them without re-discovering
from the cluster; reload does not terminate anything.

A preflight check verifies the ssh-agent holds a key before anything is torn
down (that is what install-k8s-requirements needs to reach the nodes); bypass
it with ``--skip-ssh-check`` for unencrypted key-file auth.

Because it deletes running VMs and fails any in-flight job, the script prints a
plan and asks for confirmation unless ``--yes`` is given. Use ``--dry-run`` to
see the plan without touching the cluster.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
INVENTORY = REPO_ROOT / "k8s-inventory.yaml"
VARIABLES = REPO_ROOT / "variables.yaml"
INSTALL_PLAYBOOK = REPO_ROOT / "playbooks" / "install-k8s-requirements.yaml"
GITHUB_PLAYBOOK = REPO_ROOT / "playbooks" / "setup-github-runner-scale-set.yaml"
GITLAB_PLAYBOOK = REPO_ROOT / "playbooks" / "setup-gitlab-runner-scale-set.yaml"

# Snapshot of the deployed scale sets written before anything is torn down, so
# a hard failure mid-redeploy still leaves a by-hand recovery manifest behind
# (feed it back with --from-log). Each run writes its own timestamped file so
# manifests never overwrite each other; all are kept out of git (.gitignore).
OVERVIEW_FILE_PREFIX = "redeploy-scale-sets"


def default_overview_file() -> Path:
    return REPO_ROOT / f"{OVERVIEW_FILE_PREFIX}-{datetime.now():%Y%m%d-%H%M%S}.log"

# Helm release name prefixes and their matching namespace prefixes, as created
# by the setup playbooks. Discovery keys off the release, not the namespace.
GITHUB = "github"
GITLAB = "gitlab"
KIND_META = {
    GITHUB: {
        "release_prefix": "arc-vm-",
        "ns_prefix": "gh-runner-",
        "values_url_key": "githubConfigUrl",
        "playbook": GITHUB_PLAYBOOK,
    },
    GITLAB: {
        "release_prefix": "gitlab-runner-",
        "ns_prefix": "gl-runner-",
        "values_url_key": "gitlabUrl",
        "playbook": GITLAB_PLAYBOOK,
    },
}

REQUIRED_TOOLS = ("kubectl", "helm", "ansible-playbook")


class RedeployError(Exception):
    """Fatal, user-facing error that aborts the redeploy."""


@dataclass
class RunnerScaleSet:
    kind: str          # GITHUB or GITLAB
    release: str       # Helm release name, e.g. arc-vm-linux-blktests
    namespace: str     # e.g. gh-runner-linux-blktests
    name: str          # runner_set_name suffix, e.g. linux-blktests
    config_url: str    # githubConfigUrl / gitlabUrl recovered from the cluster

    @property
    def label(self) -> str:
        return f"{self.kind}:{self.name}"


# --------------------------------------------------------------------------- #
# Shell helpers
# --------------------------------------------------------------------------- #

def _log(msg: str) -> None:
    print(msg, flush=True)


def run(cmd: list[str], *, dry_run: bool = False, check: bool = True) -> int:
    """Run a command, streaming its output. Returns the exit code."""
    printable = " ".join(cmd)
    if dry_run:
        _log(f"    [dry-run] {printable}")
        return 0
    _log(f"    $ {printable}")
    proc = subprocess.run(cmd)
    if proc.returncode != 0:
        if check:
            raise RedeployError(f"command failed ({proc.returncode}): {printable}")
        # Best-effort step: surface the failure so a partial cleanup is visible.
        _log(f"    WARNING: command exited {proc.returncode} (continuing): {printable}")
    return proc.returncode


def run_capture(cmd: list[str]) -> str:
    """Run a command and return its stdout (used for read-only discovery)."""
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RedeployError(
            f"command failed ({proc.returncode}): {' '.join(cmd)}\n{proc.stderr.strip()}"
        )
    return proc.stdout


def parse_json(text: str, *, source: str):
    """Parse JSON, converting failures into a user-facing RedeployError."""
    if not text.strip():
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise RedeployError(f"could not parse JSON output of {source}: {exc}") from exc


def preflight() -> None:
    missing = [t for t in REQUIRED_TOOLS if shutil.which(t) is None]
    if missing:
        raise RedeployError(f"required tool(s) not found on PATH: {', '.join(missing)}")
    for path in (INVENTORY, INSTALL_PLAYBOOK, GITHUB_PLAYBOOK, GITLAB_PLAYBOOK):
        if not path.exists():
            raise RedeployError(f"expected repo file is missing: {path}")


# --------------------------------------------------------------------------- #
# Kubeconfig
# --------------------------------------------------------------------------- #

_VARIABLES_KUBECONFIG_RE = re.compile(
    r'''(?m)^kubeconfig:\s*["']?([^"'#\n]+?)["']?\s*(?:#.*)?$'''
)


def _kubeconfig_from_variables() -> str | None:
    """Best-effort read of the ``kubeconfig`` value from variables.yaml.

    The playbooks read the same key, so redeploy must resolve it identically to
    keep its own kubectl/helm calls pointed at the cluster the playbooks target.
    Prefers PyYAML (a hard Ansible dependency) and falls back to a line scan so a
    missing interpreter still works. Blank/whitespace-only values are treated as
    unset, so the caller falls back to the default.
    """
    if not VARIABLES.exists():
        return None
    text = VARIABLES.read_text()
    try:
        import yaml
    except ImportError:
        yaml = None
    if yaml is not None:
        try:
            data = yaml.safe_load(text)
        except yaml.YAMLError:
            data = None
        if isinstance(data, dict):
            value = str(data.get("kubeconfig") or "").strip()
            if value:
                return value
    match = _VARIABLES_KUBECONFIG_RE.search(text)
    if match and match.group(1).strip():
        return match.group(1).strip()
    return None


def resolve_kubeconfig(cli_value: str | None) -> tuple[str, str]:
    """Resolve the kubeconfig path used for every cluster call.

    Precedence: ``--kubeconfig`` > variables.yaml ``kubeconfig`` > ~/.kube/config.
    Returns (absolute_path, source) where source is one of ``cli``, ``variables``
    or ``default``. When the source is ``cli`` the value must also be forwarded to
    the playbooks as an extra-var, because their play-level environment otherwise
    re-derives KUBECONFIG from variables.yaml and would ignore the override.
    """
    if cli_value:
        return os.path.abspath(os.path.expanduser(cli_value)), "cli"
    from_vars = _kubeconfig_from_variables()
    if from_vars:
        return os.path.abspath(os.path.expanduser(from_vars)), "variables"
    return os.path.abspath(os.path.expanduser("~/.kube/config")), "default"


def ssh_agent_has_keys() -> tuple[bool, str]:
    """Best-effort check that the ssh-agent holds a usable key.

    install-k8s-requirements.yaml SSHes to the physical nodes, so a missing key
    only surfaces mid-run (after termination). Returns (ok, detail); ok is True
    when we cannot check (no ssh-add), so this never blocks a valid setup.
    """
    if not os.environ.get("SSH_AUTH_SOCK"):
        return False, "no SSH agent found (SSH_AUTH_SOCK is not set)"
    if shutil.which("ssh-add") is None:
        return True, "ssh-add not available; skipping agent key check"
    proc = subprocess.run(["ssh-add", "-l"], capture_output=True, text=True)
    if proc.returncode == 0:
        count = len([ln for ln in proc.stdout.splitlines() if ln.strip()])
        return True, f"{count} identit{'y' if count == 1 else 'ies'} loaded"
    if proc.returncode == 1:
        return False, "the SSH agent has no identities loaded"
    return False, "could not contact the SSH agent"


# --------------------------------------------------------------------------- #
# Discovery
# --------------------------------------------------------------------------- #

def _helm_release_url(release: str, namespace: str, key: str) -> str | None:
    """Recover githubConfigUrl / gitlabUrl from a release's computed values."""
    # -a/--all dumps computed values (supplied + chart defaults), so the key is
    # present regardless of how the value was originally passed.
    out = run_capture(["helm", "get", "values", release, "-n", namespace, "-a", "-o", "json"])
    data = parse_json(out, source=f"helm get values {release}")
    if isinstance(data, dict):
        value = data.get(key)
        if value:
            return str(value)
    return None


def _github_url_fallback(namespace: str) -> str | None:
    """Fall back to the AutoscalingRunnerSet CR for the GitHub config URL."""
    try:
        out = run_capture([
            "kubectl", "get", "autoscalingrunnerset", "-n", namespace,
            "-o", "jsonpath={.items[0].spec.githubConfigUrl}",
        ])
    except RedeployError:
        return None
    return out.strip() or None


def discover(kinds: list[str]) -> list[RunnerScaleSet]:
    """Discover runner scale sets from the installed Helm releases."""
    releases = parse_json(run_capture(["helm", "list", "-A", "-o", "json"]), source="helm list") or []
    found: list[RunnerScaleSet] = []
    for rel in releases:
        name, namespace = rel["name"], rel["namespace"]
        for kind in kinds:
            meta = KIND_META[kind]
            prefix = meta["release_prefix"]
            if not name.startswith(prefix):
                continue
            suffix = name[len(prefix):]
            if not suffix:
                _log(f"  skipping release {name!r} in {namespace}: empty runner name")
                break
            url = _helm_release_url(name, namespace, meta["values_url_key"])
            if url is None and kind == GITHUB:
                url = _github_url_fallback(namespace)
            found.append(RunnerScaleSet(
                kind=kind, release=name, namespace=namespace, name=suffix,
                config_url=url or "",
            ))
            break
    found.sort(key=lambda s: (s.kind, s.name))
    return found


_OVERVIEW_HEADER_RE = re.compile(r"^\[(github|gitlab)\]\s+(.+?)\s*$")
_OVERVIEW_FIELD_RE = re.compile(r"^(url|namespace|release):\s*(.+?)\s*$")
_OVERVIEW_KUBECONFIG_RE = re.compile(r"^Target cluster kubeconfig:\s+(.+?)\s+\(from .+\)$")


def parse_overview(path: Path) -> tuple[list[RunnerScaleSet], str | None]:
    """Load runner scale sets and their target kubeconfig from an overview."""
    if not path.exists():
        raise RedeployError(f"overview log not found: {path}")
    sets: list[RunnerScaleSet] = []
    kubeconfig: str | None = None
    current: dict[str, str] | None = None

    def flush() -> None:
        nonlocal current
        if current is None:
            return
        missing = [f for f in ("name", "namespace", "release", "url") if not current.get(f)]
        if missing:
            raise RedeployError(
                f"malformed overview entry [{current['kind']}] {current.get('name', '?')} "
                f"in {path}: missing {', '.join(missing)}"
            )
        sets.append(RunnerScaleSet(
            kind=current["kind"], release=current["release"],
            namespace=current["namespace"], name=current["name"],
            config_url=current["url"],
        ))
        current = None

    for raw in path.read_text().splitlines():
        stripped = raw.strip()
        target = _OVERVIEW_KUBECONFIG_RE.match(stripped)
        if target:
            kubeconfig = target.group(1)
            continue
        header = _OVERVIEW_HEADER_RE.match(stripped)
        if header:
            flush()
            current = {"kind": header.group(1), "name": header.group(2)}
            continue
        if current is not None:
            field = _OVERVIEW_FIELD_RE.match(stripped)
            if field:
                current[field.group(1)] = field.group(2)
    flush()

    if not sets:
        raise RedeployError(f"no runner scale sets found in {path}")
    sets.sort(key=lambda s: (s.kind, s.name))
    return sets, kubeconfig


# --------------------------------------------------------------------------- #
# Terminate / recreate
# --------------------------------------------------------------------------- #

def terminate(scale_set: RunnerScaleSet, *, dry_run: bool) -> None:
    """Stop new jobs and kill active runs for one scale set.

    ``helm uninstall`` removes the ARC listener / GitLab runner manager so
    nothing pulls new work; the KubeVirt VMs the jobs spawned are not owned by
    the release, so they are deleted explicitly.
    """
    _log(f"  -> terminating {scale_set.label} (release {scale_set.release}, ns {scale_set.namespace})")
    run(["helm", "uninstall", scale_set.release, "-n", scale_set.namespace],
        dry_run=dry_run, check=False)
    for resource in ("vm", "vmi"):
        run(["kubectl", "delete", resource, "--all", "-n", scale_set.namespace,
             "--ignore-not-found=true", "--timeout=180s"],
            dry_run=dry_run, check=False)


def recreate_argv(scale_set: RunnerScaleSet, *, relative: bool = False,
                  kubeconfig: str | None = None) -> list[str]:
    """Build the ansible-playbook argv that recreates one scale set.

    Auth extra-vars are intentionally empty so the setup playbook reuses the
    existing secret instead of prompting. With ``relative=True`` the inventory
    and playbook paths are relative to the repo root, for a copy-pasteable
    command in the overview manifest. ``kubeconfig`` is only passed when it was
    overridden on the CLI; otherwise the playbook reads it from variables.yaml.
    """
    if scale_set.kind == GITHUB:
        extra_vars = {
            "runner_set_name": scale_set.name,
            "github_config_url": scale_set.config_url,
            "arc_github_app_id": "",
            "arc_github_app_installation_id": "",
            "arc_github_app_private_key_path": "",
            "github_token": "",
        }
    else:
        extra_vars = {
            "runner_set_name": scale_set.name,
            "gitlab_url": scale_set.config_url,
            "gitlab_runner_token": "",
        }
    if kubeconfig:
        extra_vars["kubeconfig"] = kubeconfig
    inventory = INVENTORY
    playbook = KIND_META[scale_set.kind]["playbook"]
    if relative:
        inventory = inventory.relative_to(REPO_ROOT)
        playbook = playbook.relative_to(REPO_ROOT)
    return ["ansible-playbook", "-i", str(inventory), str(playbook),
            "-e", json.dumps(extra_vars)]


def recreate(scale_set: RunnerScaleSet, *, dry_run: bool, kubeconfig: str | None = None) -> None:
    """Recreate one scale set via its setup playbook, reusing the auth secret."""
    _log(f"  -> redeploying {scale_set.label} ({scale_set.config_url})")
    run(recreate_argv(scale_set, kubeconfig=kubeconfig), dry_run=dry_run)


# --------------------------------------------------------------------------- #
# install-k8s-requirements
# --------------------------------------------------------------------------- #

def _password_file(contents: str, registry: list[str]) -> str:
    """Write a secret to a private temp file, tracking it for cleanup first.

    The path is appended to ``registry`` before the secret is written, so an
    interrupt mid-write still leaves the file registered for deletion.
    mkstemp() creates the file with 0600, so it is never group/world readable.
    """
    fd, path = tempfile.mkstemp(prefix="blktests-redeploy-")
    registry.append(path)
    with os.fdopen(fd, "w") as handle:
        handle.write(contents)
    return path


def install_requirements(vault_pw: str | None, become_pw: str | None, *, dry_run: bool,
                         kubeconfig: str | None = None) -> None:
    """Re-run install-k8s-requirements.yaml (reads secrets.enc, uses become)."""
    _log("  -> re-running install-k8s-requirements.yaml")
    cmd = ["ansible-playbook", "-i", str(INVENTORY), str(INSTALL_PLAYBOOK)]
    if kubeconfig:
        cmd += ["-e", json.dumps({"kubeconfig": kubeconfig})]
    tmp_files: list[str] = []
    try:
        if dry_run:
            # Show the equivalent interactive invocation without materializing
            # any password files.
            run(cmd + ["--ask-vault-pass", "--ask-become-pass"], dry_run=True)
            return
        vault_file = _password_file(vault_pw or "", tmp_files)
        cmd += ["--vault-password-file", vault_file]
        if become_pw is not None:
            # Passed via a file (-e @file), never on argv, to keep it out of ps.
            become_file = _password_file(f"ansible_become_password: {json.dumps(become_pw)}\n", tmp_files)
            cmd += ["-e", f"@{become_file}"]
        run(cmd)
    finally:
        for path in tmp_files:
            try:
                os.remove(path)
            except OSError:
                pass


# --------------------------------------------------------------------------- #
# Overview manifest
# --------------------------------------------------------------------------- #

def build_overview(scale_sets: list[RunnerScaleSet], *, reloaded_from: Path | None = None,
                   kubeconfig: str | None = None, kubeconfig_is_override: bool = False) -> str:
    """Render the recovery manifest: every scale set and how to redeploy it by
    hand. The manifest can be fed back to the script with --from-log."""
    # Only forward the kubeconfig to the by-hand commands when it was overridden
    # on the CLI; otherwise those commands read it from variables.yaml like a
    # normal run from this worktree.
    cmd_kubeconfig = kubeconfig if kubeconfig_is_override else None
    line = "=" * 74
    out = [
        line,
        "blktests-ci redeploy - deployed runner scale sets",
        f"Captured: {datetime.now().isoformat(timespec='seconds')} (before any changes)",
        line,
    ]
    if kubeconfig is not None:
        origin = "--kubeconfig override" if kubeconfig_is_override else "variables.yaml"
        out.append(f"Target cluster kubeconfig: {kubeconfig} (from {origin})")
        out.append(line)
    if reloaded_from is not None:
        out.append(f"Loaded from {reloaded_from}; these runner scale sets are being redeployed.")
    else:
        out += [
            "These runner scale sets were live at the start of this redeploy. If the",
            "redeploy fails hard, redeploy any of them by hand from the repo root with",
            "the command shown, or feed this whole file back with --from-log.",
        ]
    install_cmd = [
        "  ansible-playbook -i k8s-inventory.yaml playbooks/install-k8s-requirements.yaml \\",
    ]
    if cmd_kubeconfig:
        install_cmd.append(f"    -e kubeconfig={shlex.quote(cmd_kubeconfig)} \\")
    install_cmd.append("    --ask-vault-pass --ask-become-pass")
    out += [
        "Auth is intentionally empty so the existing secret is reused.",
        "install-k8s-requirements.yaml is re-run separately with:",
        *install_cmd,
        line,
    ]
    if not scale_sets:
        out.append("(no runner scale sets are currently deployed)")
    for s in scale_sets:
        out += [
            f"[{s.kind}] {s.name}",
            f"    url:       {s.config_url}",
            f"    namespace: {s.namespace}",
            f"    release:   {s.release}",
            f"    redeploy:  {shlex.join(recreate_argv(s, relative=True, kubeconfig=cmd_kubeconfig))}",
            "",
        ]
    out.append(line)
    return "\n".join(out)


def emit_overview(scale_sets: list[RunnerScaleSet], overview_file: Path, *,
                  dry_run: bool, reloaded_from: Path | None = None,
                  kubeconfig: str | None = None, kubeconfig_is_override: bool = False) -> None:
    """Print the overview and, on a real run, persist it to the manifest file
    without ever overwriting an existing one."""
    overview = build_overview(scale_sets, reloaded_from=reloaded_from,
                              kubeconfig=kubeconfig, kubeconfig_is_override=kubeconfig_is_override)
    _log(overview)
    if dry_run:
        _log(f"(dry-run: overview not written; a real run writes it to {overview_file})")
        return
    if overview_file.exists():
        raise RedeployError(f"overview file already exists, refusing to overwrite: {overview_file}")
    try:
        overview_file.write_text(overview + "\n")
        _log(f"Wrote scale set overview to {overview_file}")
    except OSError as exc:
        _log(f"WARNING: could not write overview to {overview_file}: {exc}")
    _log("")


# --------------------------------------------------------------------------- #
# Plan / confirmation
# --------------------------------------------------------------------------- #

def print_plan(scale_sets: list[RunnerScaleSet], *, skip_install: bool,
               reload_from: Path | None = None) -> None:
    _log("Redeploy plan")
    _log("=============")
    step = 1
    if reload_from is not None:
        # Reload is a restore: the sets are recreated, nothing is torn down.
        _log(f"{step}. Reload the following scale set(s) from {reload_from} (no termination):")
    else:
        _log(f"{step}. Terminate active runs and stop accepting new jobs for:")
    if scale_sets:
        for s in scale_sets:
            if reload_from is not None:
                _log(f"     - {s.label:24s} {s.config_url}")
            else:
                _log(f"     - {s.label:24s} helm uninstall {s.release} (-n {s.namespace}) + delete VMs")
    else:
        _log("     - (no runner scale sets)")
    step += 1
    if not skip_install:
        _log(f"{step}. Re-run install-k8s-requirements.yaml")
        step += 1
    _log(f"{step}. Redeploy the scale sets above (reusing their existing auth secret):")
    if scale_sets:
        for s in scale_sets:
            _log(f"     - {s.label:24s} {s.config_url}")
    else:
        _log("     - (nothing to redeploy)")
    _log("")


def confirm(prompt: str) -> bool:
    try:
        return input(f"{prompt} [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        return False


def read_password_file(path: str) -> str:
    # Mirror ansible-vault's own convention: the password is the first line.
    lines = Path(path).read_text().splitlines()
    return lines[0] if lines else ""


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Redeploy a new blktests-ci version (install-k8s-requirements + runner scale sets).",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--kinds", default=f"{GITHUB},{GITLAB}",
        help="Comma-separated runner kinds to redeploy (github, gitlab).",
    )
    parser.add_argument(
        "--kubeconfig", metavar="PATH", default=None,
        help="Kubeconfig for the target cluster, used for this script's own "
             "kubectl/helm calls and forwarded to the playbooks. Overrides the "
             "'kubeconfig' value in variables.yaml (the default source).",
    )
    parser.add_argument(
        "--from-log", metavar="FILE", type=Path,
        help="Reload the runner scale sets recorded in a previous overview log and "
             "redeploy them (e.g. to resume after a failed run), instead of discovering "
             "them from the cluster. This does not terminate anything.",
    )
    parser.add_argument(
        "--skip-install-requirements", action="store_true",
        help="Skip step 1; only terminate and redeploy the runner scale sets.",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show the plan and the commands that would run; touch nothing.",
    )
    parser.add_argument(
        "-y", "--yes", action="store_true",
        help="Do not ask for confirmation before terminating active runs.",
    )
    parser.add_argument(
        "--vault-password-file",
        help="Read the ansible-vault password from this file instead of prompting.",
    )
    parser.add_argument(
        "--become-password-file",
        help="Read the sudo (become) password from this file instead of prompting.",
    )
    parser.add_argument(
        "--no-become-password", action="store_true",
        help="Do not ask for a sudo (become) password; assume passwordless sudo on the nodes.",
    )
    parser.add_argument(
        "--skip-ssh-check", action="store_true",
        help="Skip the preflight check that the ssh-agent has a key loaded "
             "(use if the nodes are reached with an unencrypted key file).",
    )
    parser.add_argument(
        "--overview-file", type=Path, default=None,
        help="Where to write the recovery manifest "
             "(default: redeploy-scale-sets-<timestamp>.log in the repo root; never overwritten).",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    kinds = [k.strip() for k in args.kinds.split(",") if k.strip()]
    unknown = [k for k in kinds if k not in KIND_META]
    if unknown:
        raise RedeployError(f"unknown --kinds value(s): {', '.join(unknown)} (choose from github, gitlab)")
    if args.no_become_password and args.become_password_file:
        raise RedeployError("--no-become-password and --become-password-file are mutually exclusive")

    preflight()

    # Resolve the target cluster's kubeconfig once and export it for every
    # subprocess (kubectl/helm here, plus the ansible-playbook runs). Playbooks
    # re-derive KUBECONFIG from variables.yaml on their localhost plays, so a
    # CLI override is additionally forwarded to them as an extra-var below.
    kubeconfig, kubeconfig_source = resolve_kubeconfig(args.kubeconfig)
    kubeconfig_is_override = kubeconfig_source == "cli"
    os.environ["KUBECONFIG"] = kubeconfig
    os.environ["K8S_AUTH_KUBECONFIG"] = kubeconfig
    kubeconfig_override = kubeconfig if kubeconfig_is_override else None
    _log(f"Target cluster kubeconfig: {kubeconfig} (from {kubeconfig_source})")
    if kubeconfig_source == "default" and args.kubeconfig is None:
        _log("  note: 'kubeconfig' is not set in variables.yaml; using the default.")

    # install-k8s-requirements SSHes to the nodes; fail fast (before any
    # termination) if the agent has no key rather than dying mid-run.
    if not args.skip_install_requirements and not args.skip_ssh_check:
        ok, detail = ssh_agent_has_keys()
        if ok:
            _log(f"SSH agent: {detail}")
        elif args.dry_run:
            _log(f"WARNING: {detail}; install-k8s-requirements.yaml would fail to reach the nodes. "
                 "Load your key with 'ssh-add <key>' before a real run.")
        else:
            raise RedeployError(
                f"{detail}. install-k8s-requirements.yaml connects to the cluster nodes over SSH "
                "and will fail without a usable key. Load it with 'ssh-add <path-to-key>', or pass "
                "--skip-ssh-check (unencrypted key-file auth) / --skip-install-requirements to bypass."
            )

    reload_from: Path | None = args.from_log
    if reload_from is not None:
        # Restore mode: take the scale set list from a saved manifest instead of
        # the live cluster (the sets may already be torn down after a failed run).
        _log(f"Loading runner scale sets from {reload_from}...")
        loaded_sets, overview_kubeconfig = parse_overview(reload_from)
        if overview_kubeconfig:
            overview_kubeconfig = os.path.abspath(os.path.expanduser(overview_kubeconfig))
            if overview_kubeconfig != kubeconfig and args.kubeconfig is None:
                raise RedeployError(
                    f"overview targets kubeconfig {overview_kubeconfig}, but this worktree targets "
                    f"{kubeconfig}. Pass --kubeconfig {shlex.quote(overview_kubeconfig)} to restore "
                    "the recorded cluster, or pass an explicit different --kubeconfig to override it."
                )
            if overview_kubeconfig != kubeconfig:
                _log(f"WARNING: overriding overview kubeconfig {overview_kubeconfig}")
        scale_sets = [s for s in loaded_sets if s.kind in kinds]
        for s in scale_sets:
            _log(f"  loaded {s.label:24s} release={s.release} ns={s.namespace}")
    else:
        _log("Discovering existing runner scale sets from Helm releases...")
        scale_sets = discover(kinds)
        if scale_sets:
            for s in scale_sets:
                _log(f"  found {s.label:24s} release={s.release} ns={s.namespace}")
        else:
            _log("  none found")
    _log("")

    # Fail fast: we must know every config URL up front, because termination
    # (helm uninstall) happens before recreation and destroys the source of it.
    missing_url = [s.label for s in scale_sets if not s.config_url]
    if missing_url:
        raise RedeployError(
            "could not recover the config URL for: " + ", ".join(missing_url)
            + ". Refusing to terminate what cannot be recreated automatically."
        )

    # Persist a fresh (timestamped, never-overwritten) manifest before touching
    # anything, so a hard failure still leaves a record of what to redeploy.
    overview_file = args.overview_file or default_overview_file()
    emit_overview(scale_sets, overview_file, dry_run=args.dry_run, reloaded_from=reload_from,
                  kubeconfig=kubeconfig, kubeconfig_is_override=kubeconfig_is_override)

    print_plan(scale_sets, skip_install=args.skip_install_requirements, reload_from=reload_from)

    if args.dry_run:
        # Surface the exact commands that would execute, then make clear that
        # nothing was changed.
        _log("Would execute:")
        if reload_from is None:
            for s in scale_sets:
                terminate(s, dry_run=True)
        if not args.skip_install_requirements:
            install_requirements(None, None, dry_run=True, kubeconfig=kubeconfig_override)
        for s in scale_sets:
            recreate(s, dry_run=True, kubeconfig=kubeconfig_override)
        _log("")
        _log("Dry run: no changes made.")
        return 0

    if not args.yes:
        if reload_from is not None:
            prompt = f"Reload {len(scale_sets)} scale set(s) from {reload_from} and (re)deploy them. Continue?"
        else:
            prompt = "This terminates active runs (deletes running VMs and fails in-flight jobs). Continue?"
        if not confirm(prompt):
            _log("Aborted.")
            return 1

    # Gather credentials up front so the run is unattended after this point.
    vault_pw: str | None = None
    become_pw: str | None = None
    if not args.skip_install_requirements:
        if args.vault_password_file:
            vault_pw = read_password_file(args.vault_password_file)
        else:
            vault_pw = getpass.getpass("Ansible vault password (for secrets.enc): ")
        if args.no_become_password:
            become_pw = None
        elif args.become_password_file:
            become_pw = read_password_file(args.become_password_file)
        else:
            become_pw = getpass.getpass("Sudo (become) password for cluster nodes [empty if passwordless]: ") or None

    if reload_from is None:
        _log("")
        _log("Step: terminating active runs and freezing new job acceptance")
        for s in scale_sets:
            terminate(s, dry_run=False)

    if not args.skip_install_requirements:
        _log("")
        _log("Step: install-k8s-requirements.yaml")
        install_requirements(vault_pw, become_pw, dry_run=False, kubeconfig=kubeconfig_override)

    _log("")
    _log("Step: redeploying runner scale sets")
    failures: list[str] = []
    for s in scale_sets:
        try:
            recreate(s, dry_run=False, kubeconfig=kubeconfig_override)
        except RedeployError as exc:
            failures.append(f"{s.label}: {exc}")
            _log(f"  ERROR redeploying {s.label}: {exc}")

    _log("")
    if failures:
        _log("Redeploy finished with errors:")
        for line in failures:
            _log(f"  - {line}")
        return 1
    _log("Redeploy complete.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RedeployError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(2)
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(130)
