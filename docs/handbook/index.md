# The Claude Code SRE Handbook

A practical series on using Claude Code for Kubernetes incident response — from first investigation to automated pull requests.

## What this is

Can a general-purpose coding agent actually do SRE work on Kubernetes? We ran Claude Code against real failure scenarios — from a race condition in a live checkout service to a full benchmark suite — and built a watcher that turns alerts into draft PRs. Some results surprised us.

Every post ships an artifact: code, transcripts, benchmark data, or a working demo.

## Part 1 — Frontier

1. **The Harness Problem** — why most AI SRE tools hit a capability cliff, and what a code-runtime harness changes.
2. **From Investigation to PR** — Sonnet 4.6 with a small Skill resolves a TOCTOU race in a live ecommerce service end-to-end. Six minutes with the Skill, thirteen without.
3. **Claude Code on k8s-ai-bench** — 24 canonical Kubernetes failures, measured. 23/24 with the Skill — including one verifier-gaming pass we call out.
4. **On-Demand vs Always-On — Choosing** — two architectures, different failure modes. A short read before keyboard time.
5. **Building the Always-On Watcher** — alert to draft PR in six minutes, $0.68 per incident, human as the only un-draft path.

Part 2 — open-source models on the same problems — is on the way.

## Source

All code, scenarios, and benchmark data are in the [GitHub repo](https://github.com/har-ki/claude-code-sre-handbook).

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](https://github.com/har-ki).*
