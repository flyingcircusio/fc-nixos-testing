#!/usr/bin/env python3

"""
release/update-nixpkgs.py is designed to be used by a release manager by hand.
This is some experimentation to allow more automation. In the end we want to merge
both together I guess.

Desired workflow:
* get executed in a given interval (e.g. daily - channel bumps are happening approximately every other day)
* pull latest release into fc fork (rebase strategy)
    * post error on merge conflict
* if new:
    * push to integration branch
    * update fc-nixos & create PR
    * comment diff/changelog since last commit into PR
On Merge (fc-nixos):
    * merge updated nixpkgs into release-XX branch

Open questions:
    * branch for each update attempt?
        * probably yes, makes it easier to just merge one
        * add `Closes #XXX` for each previous update attempt to avoid stale PRs
        * alternatively: explore how to accept an older update commit from the update PR without too much manual intervention.

Todo:
    * click?
    * service account / bot user on GitHub
    * commit / PR / comment
    * make it reasonably runnable locally
    * on_merge: merge nixpkgs tracking branch back via GHA
"""


from argparse import ArgumentParser
from dataclasses import dataclass
from logging import info, warning, basicConfig, INFO
from os import path
from subprocess import check_output
from sys import exit

from git import Repo, Commit
from git.exc import GitCommandError


NIXOS_VERSION_PATH = "release/nixos-version"
PACKAGE_VERSIONS_PATH = "release/package-versions.json"
VERSIONS_PATH = "release/versions.json"


@dataclass
class NixpkgsRebaseResult:
    upstream_commit: Commit

    # This is the latest commit on the release branch in our fork.
    # If we have multiple consecutive updates, it is not the same as
    # fork_before_rebase since this is the state of the tracking branch before
    # the last rebase. This commit is important to generate the full
    # changelog.
    fork_commit: Commit
    fork_before_rebase: Commit
    fork_after_rebase: Commit


def nixpkgs_repository(directory: str, upstream: str, origin: str) -> Repo:
    if path.exists(directory):
        repo = Repo(directory)
    else:
        repo = Repo.clone_from(directory, origin)

    for name, url in dict(origin=origin, upstream=upstream).items():
        if name in repo.remotes and repo.remotes[name].url != url:
            repo.delete_remote(name)
        if name not in repo.remotes:
            repo.create_remote(name, url)

        getattr(repo.remotes, name).fetch()

    return repo


def rebase_nixpkgs(nixpkgs_repo: Repo, branch_to_rebase: str, integration_branch: str) -> NixpkgsRebaseResult | None:
    if nixpkgs_repo.is_dirty():
        raise Exception("Repository is dirty!")

    if not any(integration_branch == head.name for head in nixpkgs_repo.heads):
        tracking_branch = nixpkgs_repo.create_head(integration_branch, f"origin/{branch_to_rebase}")
        tracking_branch.checkout()
    else:
        nixpkgs_repo.git.checkout(integration_branch)

    latest_upstream = nixpkgs_repo.refs[f"upstream/{branch_to_rebase}"].commit
    common_grounds = nixpkgs_repo.merge_base(f"upstream/{branch_to_rebase}", "HEAD")
    if all(latest_upstream.hexsha != commit.hexsha for commit in common_grounds):
        info(f"Latest commit of {branch_to_rebase} is '{latest_upstream.hexsha}' which is not part of our fork, rebasing.")
        current_state = nixpkgs_repo.head.commit
        try:
            nixpkgs_repo.git.rebase(f"upstream/{branch_to_rebase}")
        except GitCommandError as e:
            warning(f'Rebase failed:\n{e.stderr}')
            nixpkgs_repo.git.rebase(abort=True)
            warning("Aborted rebase.")
            return None

        nixpkgs_repo.git.push(force_with_lease=True)

        return NixpkgsRebaseResult(
            upstream_commit=latest_upstream,
            fork_commit=nixpkgs_repo.refs[f"origin/{branch_to_rebase}"].commit,
            fork_before_rebase=current_state,
            fork_after_rebase=nixpkgs_repo.head.commit
        )

    info("Nothing to do.")


def update_fc_nixos(integration_branch: str):
    check_output([
        "nix",
        "flake",
        "lock",
        "--override-input",
        "nixpkgs",
        f"github:flyingcircusio/nixpkgs-testing/{integration_branch}"
    ])
    check_output(["nix", "run", ".#buildVersionsJson"]).decode('utf-8')


def main():
    basicConfig(level=INFO)
    argparser = ArgumentParser('nixpkgs updater for fc-nixos')
    argparser.add_argument("--fc-nixos-branch", help="Branch in fc-nixos to push updates to")
    argparser.add_argument("--nixpkgs-dir", help="Directory where the nixpkgs git checkout is in", required=True)
    argparser.add_argument("--branch", help="Branch to update", required=True)
    argparser.add_argument("--upstream", help="URL to the upstream repository", required=True)
    argparser.add_argument("--origin", help="URL to push the updates to", required=True)
    argparser.add_argument("--integration-branch", help="Branch in nixpkgs where updates are tracked", required=True)
    args = argparser.parse_args()

    nixpkgs_repo = nixpkgs_repository(args.nixpkgs_dir, args.upstream, args.origin)
    if result := rebase_nixpkgs(nixpkgs_repo, args.branch, args.integration_branch):
        info(f"Updated 'nixpkgs' to '{result.fork_after_rebase.hexsha}'")
        update_fc_nixos(args.integration_branch)


if __name__ == '__main__':
    main()
