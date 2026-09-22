#!/usr/bin/env python3
"""Run Nett's safe pre-commit checkpoint workflow.

This script deliberately keeps Git operations conservative: it never resets,
amends, force-pushes, merges, tags, or creates releases.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


KNOWN_BACKUP = Path("PersonalLedger_back.xcodeproj/project.pbxproj.backup")
APP_ICON_MANIFEST = Path(
    "PersonalLedger_back/Assets.xcassets/AppIcon.appiconset/Contents.json"
)
APP_ICON_IMAGE = Path(
    "PersonalLedger_back/Assets.xcassets/AppIcon.appiconset/PersonalLedgerIcon-1024.png"
)
ASSET_CATALOG_MANIFEST = Path("PersonalLedger_back/Assets.xcassets/Contents.json")
PROJECT_FILE = Path("PersonalLedger_back.xcodeproj/project.pbxproj")
FEATURE_BRANCH = "feature/v0.2.0-product-polish"

BLOCKED_SUFFIXES = {
    ".csv",
    ".pdf",
    ".p12",
    ".mobileprovision",
    ".pem",
    ".key",
    ".cer",
}
FINANCIAL_NAME_TERMS = ("statement", "bank", "transaction", "export", "activity")


class CheckpointError(RuntimeError):
    """A safe pre-commit validation failed."""


def run_git(root: Path, *arguments: str, check: bool = True) -> str:
    """Run Git from the repository root and return standard output."""
    result = subprocess.run(
        ["git", *arguments],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "Git command failed."
        raise CheckpointError(f"git {' '.join(arguments)}: {detail}")
    return result.stdout


def status(kind: str, message: str) -> None:
    print(f"[{kind}] {message}")


def ask(prompt: str, default: bool) -> bool:
    """Ask a yes/no question, choosing the supplied default on an empty answer."""
    suffix = "[Y/n]" if default else "[y/N]"
    try:
        answer = input(f"{prompt} {suffix} ").strip().lower()
    except EOFError:
        answer = ""
    if not answer:
        return default
    return answer in {"y", "yes"}


def repository_root() -> Path:
    """Find the Git root from this script's location instead of a user path."""
    script_directory = Path(__file__).resolve().parent
    result = subprocess.run(
        ["git", "-C", str(script_directory), "rev-parse", "--show-toplevel"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise CheckpointError("This script must be run from inside a Git repository.")
    return Path(result.stdout.strip()).resolve()


def verify_personal_ledger_repository(root: Path) -> None:
    """Require stable project markers before any file could be removed or staged."""
    required_paths = [PROJECT_FILE, Path("PersonalLedger_back"), Path("LedgerTests")]
    missing = [str(path) for path in required_paths if not (root / path).exists()]
    if missing:
        raise CheckpointError(
            "This does not look like the PersonalLedger repository. Missing: "
            + ", ".join(missing)
        )

    readme = root / "README.md"
    remote = run_git(root, "config", "--get", "remote.origin.url", check=False)
    readme_mentions_project = readme.exists() and "PersonalLedger" in readme.read_text(
        encoding="utf-8", errors="replace"
    )
    if not readme_mentions_project and "PersonalLedger" not in remote:
        raise CheckpointError(
            "Project markers were found, but neither README nor origin identifies PersonalLedger."
        )
    status("OK", f"Verified PersonalLedger repository: {root}")


def remove_known_backup(root: Path, dry_run: bool) -> None:
    """Remove only the exact, known Xcode backup file—not arbitrary backups."""
    backup = root / KNOWN_BACKUP
    if not backup.exists():
        return
    if not backup.is_file():
        raise CheckpointError(f"Known backup path is not a file: {KNOWN_BACKUP}")
    if dry_run:
        status("OK", f"Would remove known local backup: {KNOWN_BACKUP}")
        return
    backup.unlink()
    status("OK", f"Removed known local backup: {KNOWN_BACKUP}")


def verify_app_icon(root: Path) -> None:
    """Ensure the complete AppIcon asset exists before anything is staged."""
    manifest_path = root / APP_ICON_MANIFEST
    image_path = root / APP_ICON_IMAGE
    catalog_manifest_path = root / ASSET_CATALOG_MANIFEST
    missing = [
        str(path)
        for path in (APP_ICON_MANIFEST, APP_ICON_IMAGE, ASSET_CATALOG_MANIFEST)
        if not (root / path).is_file()
    ]
    if missing:
        raise CheckpointError("AppIcon is incomplete. Missing: " + ", ".join(missing))

    try:
        contents = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CheckpointError(f"Cannot read AppIcon Contents.json: {error}") from error

    images = contents.get("images", [])
    has_expected_image = any(
        image.get("filename") == APP_ICON_IMAGE.name
        and image.get("platform") == "ios"
        and image.get("size") == "1024x1024"
        for image in images
        if isinstance(image, dict)
    )
    if not has_expected_image:
        raise CheckpointError(
            "AppIcon Contents.json must reference PersonalLedgerIcon-1024.png "
            "as the iOS 1024x1024 icon."
        )
    status("OK", "AppIcon manifest and 1024x1024 image are present")


def report_app_icon_setting(root: Path) -> None:
    project_text = (root / PROJECT_FILE).read_text(encoding="utf-8", errors="replace")
    expression = r"ASSETCATALOG_COMPILER_APPICON_NAME\s*=\s*AppIcon\s*;"
    if re.search(expression, project_text):
        status("OK", "Explicit AppIcon target setting found")
    else:
        status(
            "WARNING",
            "AppIcon builds through Xcode's current automatic discovery, but the target "
            "does not explicitly set ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon.",
        )


def candidate_files(root: Path, dry_run: bool) -> list[str]:
    """Collect tracked changes and non-ignored untracked files without staging them."""
    paths: set[str] = set()
    for arguments in (
        ("diff", "--name-only"),
        ("diff", "--cached", "--name-only"),
        ("ls-files", "--others", "--exclude-standard"),
    ):
        paths.update(line for line in run_git(root, *arguments).splitlines() if line)

    # In dry-run mode model the one permitted cleanup so the preview can proceed.
    if dry_run:
        paths.discard(KNOWN_BACKUP.as_posix())
    return sorted(paths)


def blocked_reason(relative_path: str) -> str | None:
    path = Path(relative_path)
    lower_name = path.name.lower()
    lower_parts = {part.lower() for part in path.parts}
    if path.suffix.lower() in BLOCKED_SUFFIXES:
        return f"blocked file type ({path.suffix})"
    if lower_name == ".env" or lower_name.startswith(".env."):
        return "environment/secrets file"
    if lower_name == "project.pbxproj.backup":
        return "Xcode project backup"
    if "xcuserdata" in lower_parts or lower_name == "userinterfacestate.xcuserstate":
        return "Xcode user-specific state"
    if "deriveddata" in lower_parts:
        return "DerivedData build output"
    return None


def privacy_check(paths: list[str], stage: str) -> None:
    blocked = blocked_files(paths)
    if blocked:
        details = "; ".join(f"{path} ({reason})" for path, reason in blocked)
        raise CheckpointError(f"{stage} privacy check blocked: {details}")

    for path in paths:
        lower_name = Path(path).name.lower()
        if (
            Path(path).suffix.lower() not in {".swift", ".md", ".py"}
            and any(term in lower_name for term in FINANCIAL_NAME_TERMS)
        ):
            status("WARNING", f"Review unusually named possible financial-data file: {path}")
    status("OK", f"{stage} privacy check passed ({len(paths)} candidate files)")


def blocked_files(paths: list[str]) -> list[tuple[str, str]]:
    """Return candidate paths that must never be committed."""
    return [
        (path, reason)
        for path in paths
        if (reason := blocked_reason(path)) is not None
    ]


def choose_feature_branch_name(root: Path) -> str:
    """Let the developer choose a new branch name without changing any branch."""
    try:
        requested_name = input(f"Feature branch name [{FEATURE_BRANCH}]: ").strip()
    except EOFError:
        requested_name = ""
    branch_name = requested_name or FEATURE_BRANCH
    validation = subprocess.run(
        ["git", "check-ref-format", "--branch", branch_name],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if validation.returncode != 0:
        raise CheckpointError(f"Invalid feature branch name: {branch_name}")
    return branch_name


def create_or_switch_feature_branch(root: Path) -> str:
    """Create a branch, or switch only after confirmation if it already exists."""
    feature_branch = choose_feature_branch_name(root)
    branch_exists = run_git(root, "branch", "--list", feature_branch).strip()
    if branch_exists:
        if not ask(f"Branch {feature_branch} already exists. Switch to it?", default=False):
            raise CheckpointError("No feature branch was selected. Checkpoint stopped before staging.")
        run_git(root, "switch", feature_branch)
    else:
        run_git(root, "switch", "-c", feature_branch)
    branch = run_git(root, "branch", "--show-current").strip()
    status("OK", f"Using branch: {branch}")
    return branch


def handle_branch(root: Path, dry_run: bool) -> str:
    branch = run_git(root, "branch", "--show-current").strip()
    # Prefer the current release/* convention, while also protecting the
    # project's existing release-v* branch naming convention.
    protected_branch = branch == "main" or branch.startswith(("release/", "release-"))
    detached_head = not branch

    if not protected_branch and not detached_head:
        status("OK", f"Current branch: {branch}")
        return branch

    context = "detached HEAD" if detached_head else f"protected branch '{branch}'"
    status(
        "WARNING",
        f"You are on {context}. New development should not normally be committed directly here.",
    )
    if detached_head:
        status(
            "STOP",
            "Checkpoint commits are disabled while HEAD is detached. Create or switch to a named feature branch first.",
        )
    if dry_run:
        status("OK", f"Would offer to create and switch to {FEATURE_BRANCH}, or accept another feature branch name")
        return branch or "detached HEAD"

    if ask(f"Create and switch to a feature branch (suggested: {FEATURE_BRANCH})?", default=True):
        return create_or_switch_feature_branch(root)

    if detached_head:
        raise CheckpointError(
            "Detached HEAD requires a named feature branch before staging or committing. "
            f"Suggested branch: {FEATURE_BRANCH}."
        )
    if ask(f"Continue on protected branch '{branch}'?", default=False):
        status("WARNING", f"Continuing on protected branch: {branch}")
        return branch
    raise CheckpointError("No feature branch was selected. Checkpoint stopped before staging.")


def run_diff_check(root: Path, cached: bool) -> None:
    arguments = ("diff", "--cached", "--check") if cached else ("diff", "--check")
    try:
        run_git(root, *arguments)
    except CheckpointError as error:
        raise CheckpointError(f"Whitespace check failed: {error}") from error


def stage_changes(root: Path) -> list[str]:
    run_git(root, "add", "-A")
    run_diff_check(root, cached=True)
    staged = [line for line in run_git(root, "diff", "--cached", "--name-only").splitlines() if line]
    return staged


def unstage_blocked_files(root: Path, paths: list[str]) -> None:
    blocked = [path for path, _ in blocked_files(paths)]
    if blocked:
        run_git(root, "restore", "--staged", "--", *blocked, check=False)
        status("STOP", "Blocked files were unstaged. Their working-copy files were not deleted.")
        raise CheckpointError("A blocked/private file was found after staging.")


def print_summary(branch: str, staged_count: int, dry_run: bool) -> None:
    title = "Nett Checkpoint (dry run)" if dry_run else "Nett Checkpoint"
    print("\n--------------------------------")
    print(title)
    print("--------------------------------")
    print(f"Branch: {branch}")
    print("AppIcon: OK")
    print("Privacy check: OK")
    print("Git diff check: OK")
    print(f"Staged files: {staged_count}")
    print("--------------------------------")


def commit_and_optionally_push(root: Path, branch: str) -> None:
    if not ask("Commit these changes?", default=False):
        status("OK", "Files remain staged. No commit was created.")
        return

    default_message = "feat: improve imports, intelligence, and home dashboard"
    try:
        message = input(f"Commit message [{default_message}]: ").strip()
    except EOFError:
        message = ""
    run_git(root, "commit", "-m", message or default_message)
    status("OK", "Commit created successfully.")

    if ask("Push this branch to origin?", default=False):
        run_git(root, "push", "-u", "origin", branch)
        status("OK", f"Pushed {branch} to origin.")
    else:
        status("OK", "Commit was not pushed.")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Nett's safe Git checkpoint workflow.")
    parser.add_argument("--dry-run", action="store_true", help="Show checks and planned actions without changing files or Git state.")
    arguments = parser.parse_args()

    try:
        root = repository_root()
        verify_personal_ledger_repository(root)
        remove_known_backup(root, arguments.dry_run)
        verify_app_icon(root)
        report_app_icon_setting(root)

        candidates = candidate_files(root, arguments.dry_run)
        already_staged = [
            line for line in run_git(root, "diff", "--cached", "--name-only").splitlines() if line
        ]
        if blocked_files(already_staged):
            if arguments.dry_run:
                status("STOP", "A blocked/private file is already staged; normal mode would unstage it.")
            else:
                unstage_blocked_files(root, already_staged)
            return 1
        privacy_check(candidates, "Candidate")
        branch = handle_branch(root, arguments.dry_run)

        if arguments.dry_run:
            run_diff_check(root, cached=False)
            run_diff_check(root, cached=True)
            status("OK", f"Would stage {len(candidates)} non-ignored candidate files")
            print_summary(branch, len(candidates), dry_run=True)
            return 0

        staged = stage_changes(root)
        unstage_blocked_files(root, staged)
        privacy_check(staged, "Staged")
        name_status = run_git(root, "diff", "--cached", "--name-status").strip()
        print("\nStaged files:")
        print(name_status or "(none)")
        print_summary(branch, len(staged), dry_run=False)
        commit_and_optionally_push(root, branch)
        return 0
    except CheckpointError as error:
        status("STOP", str(error))
        return 1


if __name__ == "__main__":
    sys.exit(main())
