# DevScripts submission process

Repository: https://github.com/mcv19/rauthy-proxmox-community-scripts

This repository is a fork of `community-scripts/DevScripts` so a pull request can retain upstream history and target `community-scripts/DevScripts:main` directly.

- `main`: upstream baseline.
- `rauthy-testing`: installer, updater, metadata, documentation, and automated tests. Default branch for personal testing.
- `feat/rauthy`: initial contribution candidate containing only `ct/rauthy.sh`, `install/rauthy-install.sh`, and `json/rauthy.json`. It remains an experimental candidate until the gates below are resolved.

No upstream issue or PR has been opened. Testing and local changes can continue without notifying maintainers.

## Submission gates

1. Complete the real AMD64 checklist in `docs/rauthy/amd64-proxmox-test.md` and record results using `docs/rauthy/test-report-template.md`. ARM64 host tests are optional for your setup; do not claim them.
2. Review the current upstream `AGENTS.md`, `.github/agents/pve-script-creator.agent.md`, and PR template. The tested prototype **does not yet conform to all DevScripts conventions**:
   - `AGENTS.md`: “ct/ and install/ scripts define exactly one function: update_script() in the CT script. Nothing else.” The prototype defines reusable extraction, config, health, and rollback helpers.
   - Deployment is native, but the binary comes from an official OCI image via `skopeo`/`umoci`. Existing shared release helpers do not extract OCI images. Replace this with an approved shared helper/source build approach, or obtain a maintainer exception for the chosen prebuilt-binary approach.
   - Full offline database/binary recovery currently uses custom tar backups/version bookkeeping, instead of the project's standard deployment/backup helpers. Recovery must keep database and binary versions together; a refactor must preserve that behavior.
   - The prototype has a dedicated service user, a root-only initial credential file, Python-generated credentials/config, and an explicit initial daemon reload. Those differ from the current project instructions and must be revised or explicitly accepted before submission.
   - The current dependency list uses `apt-get` and includes core packages; normalize it to current project conventions during that review.
3. Verify eligibility and artifact policy with maintainers if necessary. On 2026-10-06, Rauthy had 1,362 stars, was created on 2023-07-01, was actively maintained, and release v0.37.0 exposed a source tarball URL but no uploaded standalone binary assets. State clearly that the installable prebuilt artifact is the official multi-architecture image. Do not describe it as an uploaded GitHub binary release.
4. Apply agreed changes to both the testing and contribution branches, rerun tests, and recheck on your real Proxmox host if behavior changed.
5. Fill the current upstream PR template. Report automated/container tests separately from real Proxmox tests. For AI disclosure: Codex, GPT-6 family, authored the prototype and tests and reviewed the implementation. The exact model variant/reasoning level was not exposed to this task; do not invent it. The attempted Claude implementation handoff did not execute; it contributed no implementation.

## Open the PR after these gates pass

Review the final three-file diff and run this command when you choose to submit:

```bash
gh pr create \
  --repo community-scripts/DevScripts \
  --base main \
  --head mcv19:feat/rauthy \
  --title "Add Rauthy native LXC script" \
  --body-file docs/rauthy/pr-description-draft.md
```

The draft description is on the testing branch. Replace placeholders and unresolved convention notes with the actual final implementation/results first. Do not check “tested thoroughly” or Proxmox/ARM64 boxes based only on the automated Docker harness.
