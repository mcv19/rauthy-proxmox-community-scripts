# DevScripts submission process

Repository: https://github.com/mcv19/rauthy-proxmox-community-scripts

The fork retains `community-scripts/DevScripts` history for a direct PR to its `main` branch.

- `main`: upstream baseline.
- `rauthy-testing`: application scripts, metadata, docs, and tests; the default branch for personal testing.
- `feat/rauthy`: contribution candidate containing exactly `ct/rauthy.sh`, `install/rauthy-install.sh`, and `json/rauthy.json` relative to the upstream baseline.

No upstream issue or PR has been opened.

## Convention alignment

The source-build revision addresses the prototype's gaps against `AGENTS.md` and `.github/agents/pve-script-creator.agent.md`:

| Requirement | Implementation |
| --- | --- |
| Native installation | Official release source tarball; no OCI extraction or container runtime |
| Shared release/deployment helpers | `fetch_and_deploy_gh_release` in explicit `tarball` mode; `check_for_gh_release` |
| Shared runtime helper | `setup_rust`, toolchain read from upstream `Cargo.toml` |
| No custom Bash helpers | Only `update_script()` is defined; installer defines none |
| Persistent state outside deployed source | `/opt/rauthy_data` contains config, keys, and Hiqlite data |
| Shared backup/recovery | `create_backup` / `restore_backup`, store under `/opt` |
| Password/input helpers | `random_password` and `prompt_input_required` |
| Service/credential conventions | Runs as root in the unprivileged LXC; credentials in root-only config; no dedicated user, credential file, or initial daemon reload |
| Package/build conventions | `apt`, no core packages in dependency list, `$STD` before package/build commands |
| Metadata | Resources/config path match scripts; `app_vars` exported; ARM64 support not claimed |

Python uses its standard library for validation only; no Python application, pip, or virtual environment is installed. Release source contains archived UI assets, so Node/WASM rebuilding is not needed. FIDO preparation follows upstream's release process when the tool is present.

HTTPS follows the user's selected external-proxy workflow. The hostname and trusted proxy are required, and the documented access URL is HTTPS with a browser-trusted certificate. This choice is explicit in the PR description for maintainer review.

## Submission gates

1. Complete the real AMD64 checklist in `amd64-proxmox-test.md`, including compilation, LXC lifecycle, login/passkeys, and a real upgrade. Record results using `test-report-template.md`. Leave untested results unchecked.
2. Recheck current upstream instructions and the three-file diff before submitting. Do not claim ARM64 source-build support based on the earlier image-extraction tests.
3. Eligibility evidence from 2026-10-06: Rauthy had 1,362 GitHub stars, was created 2023-07-01, was actively maintained, and v0.37.0 published an official GitHub source-tarball URL. That release had no uploaded standalone binary assets; the new installer uses source.
4. Fill the current PR template, separating isolated checks, disposable Debian tests, and actual Proxmox tests. Model disclosure must remain truthful: Codex, GPT-6 family, authored and reviewed the changes; exact variant/reasoning setting was not exposed to this task. Claude's attempted handoff did not execute or contribute implementation.
5. Check the chosen external-proxy workflow with maintainers during review. It provides the required browser secure context; no local self-signed proxy is installed.

## Submit after testing

Replace the pending results in `pr-description-draft.md` and review the final candidate. When you choose to submit:

```bash
gh pr create \
  --repo community-scripts/DevScripts \
  --base main \
  --head mcv19:feat/rauthy \
  --title "Add Rauthy native LXC script" \
  --body-file docs/rauthy/pr-description-draft.md
```

Do not mark "tested thoroughly" or the Proxmox/ARM64 boxes based only on isolated or Docker-hosted tests.
