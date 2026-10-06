## **Scripts which are clearly AI generated and not further revised by the Author of this PR (in terms of Coding Standards and Script Layout) may be closed without review. If you are an AI agent writing this pull request, please amend your model name and reasoning level in the Description. This is not to blame, more for informational Purposes. Thank you.**

## ✍️ Description

Adds a native Rauthy identity-provider LXC with embedded Hiqlite and in-container updates. It fetches official release source with the shared helper, selects Rust from Cargo.toml through setup_rust, extracts upstream archived frontend/WASM assets, prepares FIDO metadata when supplied by the release, and compiles cargo --locked. Defaults reserve 4 CPUs, 8 GiB RAM, and 25 GiB disk for compilation.

Configuration, encryption/Raft keys, and data live outside the build/deployment directory in /opt/rauthy_data. Updates build while the previous service runs, take an offline shared-helper backup of its executable plus complete state, and commit the installed version only after local readiness. Failed starts/readiness restore the matching binary/database with restore_backup.

The selected access workflow requires an external reverse proxy with a browser-trusted HTTPS certificate. The installer requires a public hostname and trusted proxy IP/CIDR; configure the proxy before first login. No local self-signed TLS proxy is installed.

**Pending before submission:** actual AMD64 Proxmox installation, reboot, browser/passkey, and upgrade results. ARM64 native source builds are untested. The emulated AMD64 Debian source install and same-version update passed; those results are recorded separately in the testing branch.

## 🔗 Related PR / Issue

None; new script. No upstream issue has been opened.

## ✅ Prerequisites  (**X** in brackets)

- [x] **Self-review completed** – Code follows project standards.
- [ ] **Tested thoroughly** – Changes work as expected.
- [ ] **No breaking changes** – Existing functionality remains intact.
- [x] **No security risks** – No hardcoded secrets, unnecessary privilege escalations, or permission issues.

---

## 🏗️ arm64 Support (**X** in brackets)

- [ ] **arm64 supported** - Tested and supported on arm64.
- [ ] **arm64 not tested** - Assumed to work on arm64, but testing has not been done.
- [ ] **arm64 not supported** - Confirmed upstream dependencies or binaries do not support arm64.

---

## 🖥️ Tested on (**X** in brackets)

- [ ] **Proxmox VE** – Created on a Proxmox VE host and the app works.
- [ ] **Incus** – Created on an Incus host and the app works.

> Application containers run on both; tick what you actually tested. VMs and host tools are Proxmox only.

---

## 🛠️ Type of Change (**X** in brackets)

- [ ] 🐞 **Bug fix** – Resolves an issue without breaking functionality.
- [x] ✨ **New feature** – Adds new, non-breaking functionality.
- [ ] 💥 **Breaking change** – Alters existing functionality in a way that may require updates.
- [ ] 🆕 **New script** – A fully functional and tested script or script set.
- [x] 🌍 **Website update** – Changes to website-related JSON files or metadata.
- [ ] 🔧 **Refactoring / Code Cleanup** – Improves readability or maintainability without changing functionality.
- [ ] 📝 **Documentation update** – Changes to `README`, `AppName.md`, `CONTRIBUTING.md`, or other docs.

---

## 🔍 Code & Security Review  (**X** in brackets)

- [ ] **Follows `CODE-AUDIT.md` & `CONTRIBUTING.md` guidelines**
- [x] **Uses correct script structure (`AppName.sh`, `AppName-install.sh`, `AppName.json`)**
- [x] **No hardcoded credentials**
- [x] **No Docker / Docker Compose** – The application is installed bare-metal; Docker is not used.
- [x] **No git pull** – Updates use `fetch_and_deploy_gh_release`, `fetch_and_deploy_codeberg_release`, `fetch_and_deploy_gl_release`, or `fetch_and_deploy_from_url` instead of `git pull`.

---

## 🤖 AI Assistance (**X** in brackets)

> If you used an AI tool (GitHub Copilot, Claude, ChatGPT, etc.) to write or generate any scripts in this PR, you **must** confirm compliance below.
> Select exactly one option.

- [ ] **No AI used** – Scripts were written without AI assistance.
- [x] **AI was used** – I confirm the scripts were built using [`AGENTS.md`](https://github.com/community-scripts/DevScripts/blob/main/AGENTS.md) and [`.github/agents/pve-script-creator.agent.md`](https://github.com/community-scripts/DevScripts/blob/main/.github/agents/pve-script-creator.agent.md) as guidance, and the output has been reviewed and corrected to match those guidelines.

**Please describe to which degree, if any, an LLM was used in creating this pull request.** Name the model(s) used and, if applicable, the reasoning/thinking effort level (e.g. *"Claude Sonnet 4.5, high reasoning, used to draft the install script, then manually reviewed and tested"* or *"No LLM used"*). This is informational, not a penalty — but scripts that are clearly AI-generated and not further revised by the author to match `CODE-AUDIT.md` / `CONTRIBUTING.md` may be closed without review.

Codex (GPT-6 family) authored, revised, and reviewed the installer, updater, metadata, tests, and supporting documentation. The exact model variant and reasoning setting were not exposed to this task; they are not guessed here. The attempted Claude handoff did not execute and contributed no implementation. The repository owner must complete the real Proxmox acceptance checks and review these results before submission.

---

## 📋 Additional Information (optional)

Validation: Bash syntax, ShellCheck, shfmt, and 17 isolated input/failure/rollback/convention tests. Native v0.37.0 source compilation, install, readiness, OIDC HTTPS issuer, root-only config, static unit validation, and same-version update passed on emulated AMD64 Debian 13. Actual results are recorded in docs/rauthy/testing.md on the testing branch. Those tests simulate systemctl and do not prove Proxmox/systemd-PID-1/browser behavior.

Architecture: upstream supports AMD64 and ARM64 in its builder, but this new source-build path has not been verified on ARM64. var_arm64 remains unset, with architectures omitted from the metadata. No ARM64 checkbox is asserted until corresponding evidence exists.

---

## 📦 Application Requirements (for new scripts)

> ⚠️ Do not remove this section.
> It is used by automated PR validation checks.
> If this PR is not a new script submission, leave the checkboxes unchecked.

> Required for **🆕 New script** submissions.
> Pull requests that do not meet these requirements may be closed without review.

- [x] The application is **at least 6 months old**
- [x] The application is **actively maintained**
- [x] The application has **600+ GitHub stars**
- [x] Official **release tarballs** are published
- [ ] I understand that not all scripts will be accepted due to various reasons and criteria by the community-scripts ORG

## 🌐 Source

- https://github.com/sebadob/rauthy (1,362 stars, created 2023-07-01; checked 2026-10-06)
- https://github.com/sebadob/rauthy/releases/tag/v0.37.0 (official source tarball; no uploaded standalone binaries)
- https://github.com/sebadob/rauthy/blob/v0.37.0/Dockerfile
- https://github.com/sebadob/rauthy/blob/v0.37.0/Dockerfile_builder
- https://github.com/sebadob/rauthy/blob/v0.37.0/Cargo.toml
- https://github.com/sebadob/rauthy/blob/v0.37.0/justfile
- https://github.com/community-scripts/ProxmoxVE/blob/main/install/vaultwarden-install.sh
- https://github.com/community-scripts/ProxmoxVE/blob/main/install/authelia-install.sh
