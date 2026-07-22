# SuxOS v5 — the oracle arc (assimilate the life, on rails that already run)

> **Status:** proposed — this PR is the review gate. Majors stay Colin-gated per
> production-driver doctrine; merging this doc green-lights *design*, not a release cut.
> **Method:** autonomous v5 design pass (drummer `v5-design`, 2026-07-22), gated on the v4
> post-close audit landing. Inputs, all verified live: the audit report
> (`colinxs/vault` `_meta/audits/2026-07-v4-postclose-audit.md`, GREEN, 8 findings), Colin's
> verbatim north star + oracle architecture statement (recorded 2026-07-22), epic sux#1184
> (folded spec, preserved in full), the v10 Retrieval Plane audit + its four deep-research
> verdicts (2026-07-16), a live code read of `sux`@origin/main (`9d39d1d`), current Vectorize
> limits/pricing (Cloudflare docs, 2026), and every repo's roadmap rollup
> (sux#1192, .github#655, suxos-net#106, suxlib#435, claude-config#425).
> **Owner:** m@colinxs.com.

## 1. What v5 is for — the north star, verbatim

Colin (2026-07-22): *"i want to be able to toss you information and have you organize and
assimilate it. scan email chat whatever... organize the whole life, triage, automate where
you can, help me write, draft, track people timelines, conversations, the whole shebang.
**dont go crazy tho**."*

And the architecture, his framing: vault = "concrete knowledge and notes and rigid things";
ingest = **extract text → summarize key lessons → store OPTIMIZED original (pdf shrink
etc.) → learn with ML (kNN/embeddings) = "the oracle."** Role grant: "legal medical
personal assistant advisor organizer. high trust."

v5's acceptance criterion is that sentence pair. The "dont go crazy" clause is a design
input, not a vibe: extend the existing kernel (propose→gated-act), the existing vault, and
the existing fn spine. **No new engines.**

## 2. Ground truth — how much of the oracle v4 already shipped

The single most important finding of this pass: **the oracle pipeline is ~70% live on
`main` today.** A design that "builds the oracle" would re-derive shipped code. Verified
stage by stage against `sux`@`9d39d1d` and the v4 audit's E2E matrix:

| Oracle stage (Colin's words) | Status | Evidence |
|---|---|---|
| **extract text** | ✅ shipped | `study.ts` — Workers-AI `toMarkdown` (native text + OCR), book segmentation; `_document_radar.ts` scan branch (image OCR + PDF extract); scan→vault E2E certified by audit row 8 |
| **summarize key lessons** | ✅ shipped | `study`/`oracle` distill → KV summary tier + `_kb.ts` vault mirrors (`Whitelisted.md`, `Knowledge.md`) |
| **store original** | ✅ shipped | `study.archiveKnowledge` — R2 `putBlob` (content-addressed) + `wayback` snapshot + vault provenance note; PDF branch closed as sux#1216 (COMPLETED) |
| **store *optimized* original (pdf shrink)** | ❌ missing | no shrink/compress leg in `study.ts`; the design exists (sux#1187 Part "real PDF image-shrink", folded into rollup #1192) |
| **learn via ML (embed + kNN)** | ✅ shipped | `_source.ts` chunk+embed (bge-base-en-v1.5)+brute-force-cosine substrate; **oracle's two-tier storage landed as sux#1235** with the #1242 keyspace-collision fix (#1245) — `oracle`, `study`, `advise` already converge on ONE retrieval substrate |
| **recall with citations** | ⚠️ shipped, one bug | audit row 3: vault-scoped recall cites correctly; default full-source fan-out times out reproducibly (sux#1262, fails closed instead of partial) |
| **chat/journal ingress** | ❌ missing | `imessage` fn is read-only harvest; evening-journal task writes Daily notes; nothing extracts people/timeline/conversation structure from either |
| **assimilation (KG)** | ⚠️ half-done | taxonomy Batches 1a+2 migrated; **Batch 1b blocked on sux#1224** (hardcoded `Daily/`+`Inbox/` paths); 93 orphans, 104 date-unknown, 18 collisions, blob exodus pending; `graph_health` self-contaminates its own dead-link count (sux#1261) |

Consequence: **v5 is a finishing-and-ingress arc, not a build-the-oracle arc.** Its three
real deliverables are the optimize leg, the chat/journal ingress with people/timeline
tracking, and assimilation run to done.

## 3. The oracle architecture decision

**Decision: the oracle IS the existing `_source` substrate, extended in place.** One
retrieval spine (`_source.ts` + `_embed.ts`), one vault-mirror layer (`_kb.ts`), one
ingest fan-out (`study`/`ingest`/scan-consumer). This ratifies epic sux#1184's "core
insight" — now mostly shipped — as the standing architecture, and closes the question the
folded epic left open.

Alternatives considered and rejected:

| Option | Verdict | Why |
|---|---|---|
| **A. `_source` KV brute-force kNN, extended in place** | **ADOPTED** | Already live and proven by `advise`/`oracle`/`study`; zero new Cloudflare resources; linear scan over a few hundred 768-dim vectors is microseconds (`_source.ts`'s own documented KISS rationale); per-domain `source_id` undo handles keep everything reversible |
| **B. Vectorize index now** | **DEFERRED — graduation rule below** | Real vector DB, trivially cheap at personal scale (verified 2026: 10M vectors/index, 768-dim fits under the 1,536 cap, topK≤50; a 10k-vector corpus queried 1k×/day ≈ **$0.31/month**) — but adopting it before a measured need violates "dont go crazy" and forks the substrate while KV still serves |
| **C. Resurrect the v10 Retrieval Plane (AI Search / Iceberg / sux-compute)** | **REJECTED for v5** | Its own 2026-07-16 audit: dind NO-GO as built, AI Search generation billed outside the sux governor, R2 sync lag ≤6h, 2 merge blockers; it is a *fleet-scale* search plane, and v5's corpus is one person's life. The spec stays preserved (PR sux#759) for a future arc |

**Vectorize graduation rule** (mechanical, per-domain — revisable only by editing this
table in a reviewed PR, same convention as the vX §4 decision rule):

> Graduate a `_source` domain from KV brute-force to a Vectorize index when EITHER
> (a) its chunk count exceeds **2,000** (linear-scan KV reads stop being "microseconds"),
> OR (b) measured retrieval p95 for that domain exceeds **2s** across a week.
> Migration is mechanical: same bge-base-en-v1.5 embeddings, same chunk ids/metadata
> (`source_id`, `domain`, `authority`), upsert-idempotent by construction — the
> suxos-net#34 branch already demonstrates the exact Vectorize pattern (stable vector
> id = f(sourcePath, chunkIndex)) to copy. Interface stays `putChunk`/`listChunks`/kNN;
> only the backend behind it swaps.

## 4. Workstreams and build order

Dependency shape: WS0 unblocks everything cheap; WS1 is the arc's centerpiece; WS2 runs
parallel to WS1; WS3 follows WS0; WS4 drains in the pipeline background.

### WS0 — Unblockers (first, small, all pipeline-buildable)
1. **sux#1224** — centralize hardcoded `Daily/`/`Inbox/` vault paths behind env-overridable
   constants. Gates KG Batch 1b and every journal-ingress write path below.
2. **sux#1261** — `graph_health` must exclude its own generated report from link-source
   parsing (~230 phantom dead links). The KG instrument has to be trustworthy before WS3
   drives counts to zero against it.
3. **sux#1262** — `recall` fan-out: return partial results with a `timed_out` marker per
   source instead of failing closed. The oracle's answer path must degrade, not die.

### WS1 — People, timelines, conversations (the centerpiece)
The north-star clause nothing currently serves: "track people timelines conversations."
KISS shape — **a timeline is a derived view over dated fact-notes, not a new engine.**

1. **Person-note substrate**: `people/<name>.md` profiles in the vault (typed frontmatter,
   MOC-linked, per existing knowledge-core conventions). Contacts fn seeds identity;
   fact-notes backlink in.
2. **Fact extraction on ingest** — execute **sux#1204** as specced (open issue, W2 of the
   personal-agent epic): `entities` extraction → dated fact-notes with evidence-grade
   provenance (source ref + quote span, source never altered), ambiguity → Inbox review,
   never silent. This single mechanism serves email, scans, chat, and journal alike —
   one extractor, many doors (cardinal: generalize the mechanism).
3. **Chat ingress**: extend the existing read-only `imessage` fn into a harvest pass —
   deterministic bucketing first (thread/contact/date — no LLM per message, per #1184's
   doctrine), then per-thread **conversation digests** (dated, person-linked) + fact-notes
   through the #1204 extractor. Raw messages are never mirrored into vault/R2 —
   derived notes + provenance pointers only (OPEN-1 below).
4. **Journal ingress**: the evening-journal Daily notes get an assimilation pass —
   extract durable facts/decisions/commitments into fact-notes + people backlinks (runs
   after WS0.1 so paths are stable). The existing `_agenda` kernel gains a
   people/timeline sense: upcoming-commitment and went-quiet detectors become proposals,
   never auto-acts.

### WS2 — Oracle completion (parallel with WS1)
1. **Optimize-original leg**: add pdf-shrink to `study.archiveKnowledge`'s R2 leg per
   sux#1187's already-researched design (image downscale path; buy-don't-build for
   conversion). Store both sha256 handles (original, optimized) in provenance; original
   remains authoritative.
2. **Insight-card sharpening** (small): per-source card at `knowledge/<topic>.md` — summary
   + actionable rules + provenance links (R2, wayback) — per #1184 W4 sink 2, aligned to
   the migrated taxonomy.
3. **Instrument the graduation rule**: log per-domain chunk count + retrieval latency so
   §3's rule reads from data, not anecdote.

### WS3 — Assimilation to done (after WS0)
KG Batch 1b (Daily/Inbox migration), Batches 3–5, orphan-connect (93), date-frontmatter
annotate (104), Man-vs-Inbox dedup (18), blob exodus (15 tracked PDFs → R2 via the
now-complete archive tooling). Exit: `graph_health` (fixed) green with a recorded baseline.

### WS4 — Residue hardening (pipeline drains anytime)
sux#1263 (mail label filter match-all bug — a triage-correctness landmine for any
email-secretary work), rollup gaps (suxrouter Roadmap, suxlib Needs-Colin), and the
audit's INFO-class paper cuts.

## 5. Explicitly out of scope for v5

- **The v10 Retrieval Plane** (AI Search, Iceberg lake, sux-compute dind) — preserved, not
  resurrected (§3-C).
- **Any release cut.** Minors flow autonomously per production-driver doctrine; the v5
  MAJOR cut is Colin's button after workstreams drain + a post-arc audit.
- **Portal arming** (`PORTAL_ENABLED`), **Monarch token**, **Fastmail sieve install**,
  **suxrouter#646 box fixes** — all Colin-gated operator actions, tracked in Needs-Colin
  rollups; v5 work must not depend on them landing.
- **New voice/lens work** (#1184 W1/W2) — voice lenses partially landed in v4 (sux#1229);
  further register work is not on the v5 critical path.
- **Email-secretary buildout** (#1183) beyond the #1263 bug fix — separate epic, separate arc.
- **No raw-corpus mirrors**: chat/journal ingress persists derived notes + provenance
  pointers, never full message-history copies (pending OPEN-1).
- **No new engines, no new repos, no new always-on daemons.**

## 6. Release gating

Per production-driver doctrine: **minor releases cut autonomously** as workstreams land;
**the v5 MAJOR is gated on Colin**, eligible when WS0–WS3 are drained, WS4 has no HIGH
residue, and a post-arc audit (same drummer pattern as v4's) reports GREEN. The drummer
`v5-implement` shepherds the drain and stops at cut-ready with an AMBER to Colin — it
never cuts.

## 7. OPEN decisions (marked for Colin; defaults chosen so work can start)

| # | Decision | Default (used until overridden) | Why it's yours |
|---|---|---|---|
| OPEN-1 | **Chat-harvest privacy boundary** — which channels/contacts may the iMessage/journal harvest read, and is "derived notes + provenance pointers only, no raw mirrors, exclusion list honored" the right persistence line? | Harvest ON for chat + journal; derived-only persistence; PHI-fence pattern extended to `people/` notes | Echoes folded epic #1184's unanswered Q3 — it's your private correspondence; the north star authorizes intent ("chat whatever") but not the boundary |
| OPEN-2 | **Vectorize adoption when §3's trigger fires** — a new Cloudflare resource on the sux worker | Yes-when-triggered (cost verified trivial; migration mechanical) | "No new Cloudflare resource" was #1184's constraint; this arc writes the exception rule |
| OPEN-3 | **sux#1204's needs-human gate** — the fact-extraction issue sits in the audit's Needs-Colin residue; WS1 builds directly on it | Treat the gate as "review the first extraction batch in Inbox before the cron arms" (matches its own ambiguity→Inbox design) | If the gate meant something stricter (e.g. no automated extraction at all), WS1's mechanism choice changes |

## 8. What gets seeded (when this doc merges)

Design-only mandate: this PR files nothing. On merge, drummer `v5-implement` (already
armed, gated on this PR) decomposes WS0–WS4 into pipeline issues per the epic-decomposition
design, honoring: reopen folded issues rather than duplicating them (sux#1224, #1261,
#1262, #1263, #1204 are already-filed real issues; #1187's shrink part and #1184's W4-sink-2
re-extract from their rollup entries with acceptance criteria quoted), dependency links set
(#WS-order above), and the audit's "verify against HEAD before re-implementing" warning
honored per-issue (this pass already caught two would-be re-implementations: oracle
two-tier and the R2 archive legs).
