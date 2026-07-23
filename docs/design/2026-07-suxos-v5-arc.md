# SuxOS v5 — the oracle arc (tournament synthesis: assimilate the life on the surface that already runs)

> **Status:** proposed — this PR is the review gate. Majors stay Colin-gated per
> production-driver doctrine; merging this doc green-lights *design*, not a release cut.
> **Supersedes:** the 2026-07-22 drummer single-pass version of this file (PR #661). That
> pass was one design; this document is the outcome of a three-design tournament (recall-first,
> ingest-first, kiss-minimal) scored by a judge panel on north-star fit, slim-surface,
> pipeline-buildability, and honesty, then synthesized per the panel's directive: **Design 2
> (ingest-first) wins as the spine; Design 3 supplies the build order and acceptance test;
> Design 1 supplies the instrumentation, the timeline verb, and the pre-written Vectorize
> analysis.** Where this doc and the superseded pass disagree, this doc governs.
> **Method:** all three designs were grounded in a live code read of `sux`@origin/main, the
> v4 post-close audit, and live-verified state (proposals `insights` count:0; scan→R2→queue→
> Dropbox+vault pipeline proven with a real document; MyChart multi-org pulling; recall
> vault-scoped works / full fan-out fails — sux#1262).
> **Owner:** m@colinxs.com.

## 1. What v5 is for — the north star, verbatim

Colin (2026-07-22): *"i want to be able to toss you information and have you organize and
assimilate it. scan email chat whatever... organize the whole life, triage, automate where
you can, help me write, draft, track people timelines, conversations, the whole shebang.
**dont go crazy tho**."*

And the architecture, his framing: vault = concrete/rigid knowledge; pipeline =
**extract text → summarize key lessons → store OPTIMIZED original (pdf shrink etc.) →
learn with ML (kNN/embeddings) = "the oracle."** Role grant: legal/medical/personal
assistant-advisor-organizer, high trust.

### Goals, each tied to that sentence

- **G1 — "toss you information and have you organize and assimilate it"**: every ingress
  (scan, mail, FHIR, tossed text) flows through ONE assimilation path — extract → distill →
  optimize-original → index — and becomes semantically retrievable without the caller
  naming a topic. Today only radar docs get extraction; scans get link-notes, mail gets
  triage-but-no-assimilation, FHIR sits unconsumed.
- **G2 — "scan email … organize the whole life"**: coverage closes its honest gaps —
  triage-flagged mail assimilated, structured medical data (858 FHIR resources already
  pulled) consumed into recall and the agenda, scans queryable within one radar sweep.
- **G3 — high trust ("legal medical personal assistant advisor")**: every synthesized
  answer is citation-constrained (retrieved passages only), hedged, thresholded at the
  0.68 cosine floor, `status: answered|no_match`. No uncited synthesis over
  personal/medical/legal material, ever.
- **G4 — "store OPTIMIZED original (pdf shrink etc.)"**: build #1187's designed-but-unbuilt
  image-recompression shrink leg so the R2 CAS archive tier stays cheap enough to keep
  everything.
- **G5 — "triage, automate where you can" + "track people timelines, conversations"**:
  assimilation signals (doc types, expiries, FHIR results) feed the existing proposals/
  agenda queue — which is simultaneously the W8 learner's data supply — and a query-time
  `timeline` verb assembles a person's history with citations, no new store.
- **G6 — "help me write, draft"**: served by the substrate, not a workstream — cited
  cross-domain recall IS the drafting input; no dedicated surface is added for it in v5.
- **G7 — "dont go crazy tho"**: the surface budget (§5) is **zero new surfaces in v5
  core**; the one contingent surface (a Vectorize binding) exists only as a pre-written,
  trigger-armed escape-hatch issue.

## 2. The winning architecture (Design 2's spine)

**Decision: extend the existing brute-force-KV-cosine substrate. No Vectorize in v5 core.**
The judge panel scored ingest-first highest on slim-surface because its backbone is Colin's
architecture sentence rendered as code, with zero new deployables.

### 2.1 The assimilation spine — `sux/src/fns/_assimilate.ts`

One new **internal module** (not a verb — no MCP surface change):
`assimilate({source, bytes|text, kind, domain, phi?})` composing four existing legs:

1. **extract** — `study.ts` `extractDocText` (toMarkdown, whole-doc) for PDFs/URLs;
   `ocr.ts` for images; passthrough for text.
2. **distill** — the `learnTopic()` two-tier pattern (≤500-word note, rolling summary +
   embedded passages) with guarded `llm()` `<<<DATA>>>` fencing; provenance stamped.
   Reuse, do not reinvent (per #1187's own instruction).
3. **optimize-original** — shrink (W4) → `putBlob` to R2 CAS; Dropbox stays the human
   home (storage roles LOCKED).
4. **index** — `_source.ts` chunk+embed under namespaced domains `assim:<stream>`
   (`assim:scan`, `assim:mail`, `assim:doc`, `phi:medical`) — preserving #1242's
   namespace-isolation rule and the `phi/` fence (#613).

Long inputs (book-scale) auto-route to the op-engine's Workflows runtime (the
`assimilate-pdfs` walking skeleton is the home) — routing is automatic, not caller-picked.
Fail-closed flag **`ASSIMILATE_ENABLED`** gates every unattended write, matching the
CROSS_SEMANTIC_ENABLED bar. All archive/index legs best-effort; never fail the primary note.

Ingress wiring: the **document radar is the single scan-assimilator** (it already watches
Dropbox and already extracts; scans land in `/Scans/`, radar picks them up) — the
`_ingest_queue.ts` durability contract (Dropbox+vault confirm before transit delete) is
NOT changed. Mail rides triage flags into the spine. FHIR feeds `_agenda.ts` structured
consumption + `phi:medical` distillates. Tossed text rides the existing `ingest` verb.

### 2.2 Why KV brute-force stays (and what would change it)

The binding constraint is KV's 25MiB packed-blob cap (~4–5k chunks/domain at ~5–6KB/chunk),
not cosine CPU (few-thousand-chunk linear scan is sub-ms; worst cross-domain case ~1.5s,
bounded by MAX_PAIRS). Real corpus: vault ~800 notes ≈ 2–4k chunks (INDEX_MAX 5000), mail
windowed to 1000 recent, files 3000, contacts 2000 — all inside the cap, and the code
documents this as deliberate KISS. The "distill-only, never verbatim" invariant keeps
assimilation-corpus growth sublinear in ingested bytes.

**Hot/cold mail framing (graft from Design 1):** the 1000-recent KV mail index stays
regardless, as the hot tier — exact cosine, zero-latency, content-immutability re-embed
optimization preserved (JMAP reports label moves as 'updated'; only re-embed ids lacking
embeddings). The 14k-message lifetime archive is the cold-tier question, cleanly severable
(OPEN #1).

### 2.3 The pre-written Vectorize escape hatch (Design 1's analysis, preserved as the trigger-armed issue)

Not a v5 deliverable. An issue is pre-written containing Design 1's full decision analysis,
opened only when a trigger fires:

- **Analysis preserved:** ONE embed model across tiers (`MODELS.embed`, bge-base-en-v1.5,
  768-dim, via `_embed.ts` with EMBED_BATCH=100) is a hard requirement — score
  comparability is what lets one Vectorize index merge with four KV indices in a single
  ranked answer. AutoRAG/AI Search is REJECTED: its generation bills via AI Gateway
  outside the sux request-gate governor (an ungoverned spend channel is disqualifying for
  an always-on loop), and it picks its own chunker/embedder, breaking score comparability.
  Stable vector ids `f(sourceId, chunkIdx)` for idempotent re-sync; 0.68 cosine floor
  harvested from suxos-net PR #34's calibration (on-topic bge chunks 0.65–0.75, off-topic
  <0.6 — precision-favoring for sensitive QA). One binding on the existing sux worker,
  never a parallel stack. Known cost: Vectorize index provisioning is an account-side
  action the drain can't fully self-serve — flagged in the issue as its needs-Colin step.
- **Triggers (any one fires → open the issue):** (a) any single domain blob crosses ~4.5k
  chunks / the already-logged KV write-drop degradation fires; (b) measured per-query
  multi-MiB blob load+decode becomes the latency dominator; (c) Colin demands semantic
  recall over the full lifetime mail archive (OPEN #1).
- **Guard on the guard:** per Design 1's own riskiest-assumption logic, the embedding
  choice must NOT be locked in at 14k-message scale before the answer-quality telemetry
  (W1's score logging + thumbs) shows bge-base-en-v1.5 + 0.68 is good enough for
  medical/legal QA. The telemetry gates the backfill even after a capacity trigger fires.

### 2.4 Query layer and people/timelines

`recall.ts` gains the `assim:*` and `phi:*` (auth-fenced) domains in its fan-out;
`oracle.ts` gains an `ask` action that skips per-topic namespacing — embed the question,
kNN across all domains + topic KBs, guarded-llm synthesis constrained to retrieved
passages, mandatory citations as pointers (vault path, JMAP id, R2 cas sha, FHIR resource
ref), whitelisted KBs outranking model knowledge (existing `answerSystem` contract), and
**per-domain `indexed_at` freshness in every answer** (graft from Designs 1+3).

People/timelines ship in two stages: the **query-time `timeline` action on the existing
contact fn first** (Design 1's verb — no store, no graph engine: mail by sender, calendar,
vault mentions, files, sorted chronologically with citations). Design 2's
`_people_timeline.ts` proposer + materialized `People/<name>.md` vault notes follow only
after assimilation volume exists — and only per OPEN #4.

## 3. Workstreams — each one pipeline-buildable issue, in build order

Build order (Design 3's sequencing discipline, with the oracle pulled EARLY so Colin feels
it in week one — before the spine lands, over the existing four indices):

**W0 (3 issues) → W1 → W2 → (W3 ∥ W4 ∥ W5) → (W6 ∥ W7) → W8 → W9 → W10.**

| WS | Issue (one pipeline build each) | Owning repo | Depends on |
|---|---|---|---|
| **W0.1** | **Recall fan-out fix (sux#1262)** — the feel-blocker, first, exactly Design 3's semantics: parallel per-domain scans with individual time budgets; **partial results with per-domain `degraded`/`skipped` markers, never fail-closed**; expose per-domain `indexed_at` (each index already keys on git HEAD sha / JMAP state / Dropbox cursor). File: `sux/src/fns/recall.ts`. | `SuxOS/sux` | — |
| **W0.2** | **Mail edu-label filter match-all bug (sux#1263)** — silent match-all is a triage-correctness landmine under any mail assimilation. | `SuxOS/sux` | — |
| **W0.3** | **`graph_health` self-contamination (sux#1261)** — exclude its own report from link-source parsing (~230/301 phantom dead links); the KG instrument must be trustworthy. | `SuxOS/sux` | — |
| **W1** | **`oracle ask` + day-one instrumentation** — topic-free cited answering over the EXISTING four indices + oracle KBs: embed question → W0.1 fan-out → 0.68 floor → guarded-llm `<<<DATA>>>` synthesis → `{status: answered\|no_match, answer, citations[], indexed_at per domain}`. **Graft from Design 1, non-negotiable: per-answer retrieval-score logging + thumbs-up/down from day one** — this is the data that answers the tournament's real disputed question (is bge-base-en-v1.5 + 0.68 good enough for medical/legal QA?) before any at-scale embedding lock-in. Files: `sux/src/fns/oracle.ts` (+ a shared `_answer.ts` helper if extraction is cleaner). | `SuxOS/sux` | W0.1 |
| **W2** | **`_assimilate.ts` spine** — the internal module of §2.1: extract → distill → optimize-original hook → index under `assim:*`/`phi:*`; `ASSIMILATE_ENABLED` fail-closed flag; op-engine auto-routing for oversize inputs. Acceptance: a Dropbox PDF round-trips to distillate + CAS blob + retrievable passages. The judge flagged this as the one compose-shaped issue in the arc — the issue body must enumerate the four legs with their exact existing call targets so the builder wires, not designs. | `SuxOS/sux` | W1 |
| **W3** | **Scan/radar wiring** — document radar calls the spine as its terminal step (single scan-assimilator; `_ingest_queue.ts` contract untouched; verify `/Scans/` watch-path alignment; keep MAX_PER_RUN=5). Acceptance: a real scanned document is queryable via `oracle ask` within one radar sweep. | `SuxOS/sux` | W2 |
| **W4** | **PDF shrink — #1187 spec verbatim** (reopen the folded issue in rollup #1192 first; the closed line carries the acceptance criteria): walk `/Subtype /Image` XObjects mirroring `pdfShrink()`'s metadata walk; recompress via the already-wired `env.IMAGES` binding (default 150dpi/q75); reuse `loadBoundedPdf` bomb guards; composable `shrink:{maxDpi,quality}` on `get.ts`'s pipeline stage; radar/spine archive legs apply it before `putBlob` (best-effort, never blocks the note). **Sux's pdf-lib instance only** — never pass PDFDocument across the sux/suxlib boundary (dual-package hazard). | `SuxOS/sux` | — (parallel any time; spine consumes it when present) |
| **W5** | **KV-bet observability** (the honesty patch — Design 2's named-but-unscheduled mitigation promoted to a real workstream): per-domain blob-size + chunk-count + `indexed_at` metrics, alerting on approach to the ~4.5k-chunk ceiling. Small, deterministic, and exactly what makes the triggered-escape-hatch posture safe — the KV bet becomes observable instead of silently degrading. | `SuxOS/sux` | W2 |
| **W6** | **Mail assimilation** — **triage-flagged mail only** (panel default per OPEN #6) → spine → `assim:mail` distillates; 1000-recent hot index and content-immutability optimization preserved; zero autonomous sends/moves. | `SuxOS/sux` | W2 (∥ W7) |
| **W7** | **FHIR → agenda + `phi:medical`** — **verify #1178/#986-Part-B state against HEAD first** (the durable MyChart pull ran end-to-end; grep before building): structured FHIR consumption in `_agenda.ts` (replacing subject keyword-sniffing; new-result → agenda item), compact per-resource distillates into `phi:medical` behind the `phi/` fence. FHIR/OAuth-native only — never browser auth. | `SuxOS/sux` | W2 (∥ W6) |
| **W8** | **`timeline` action on the contact fn** — query-time assembly (Design 1's verb): mail by sender (JMAP query + metadata filters), calendar events, vault mentions (`_contact_semantic.ts` + cross-links), files — chronological, cited, zero-store. Materialized `People/` notes deferred to OPEN #4. | `SuxOS/sux` | W1 (richer after W6/W7) |
| **W9** | **Toss-path E2E verification** — the `ingest` verb (already url/text/query with blob routing) routes tossed text through the spine; acceptance: `ingest` a paragraph → next index cycle → `oracle ask` retrieves it with citation. Likely small-to-zero code; the deliverable is the E2E guarantee + docs naming `ingest` the universal inbox. | `SuxOS/sux` | W2 |
| **W10** | **Oracle-feel E2E eval — the arc's acceptance test** (Design 3's WS6): (a) scan a real document → ask → cited answer naming the scan; (b) ask about a recent email → cited answer with JMAP pointer; (c) ask about a vault note → cited answer; (d) `ingest` freeform text → ask → cited answer. Green = the arc ships (feeds §7's gate). | `SuxOS/sux` | W3, W6, W9 |
| **W-V** | *(unscheduled)* **Vectorize escape hatch** — the pre-written issue of §2.3, opened only when a trigger fires AND W1's quality telemetry supports the embedding choice. | `SuxOS/sux` | trigger-armed |

Every issue is single-fn/module scale with tests, no cross-repo edits, no bot-minted
secrets. Not a build issue but sequenced alongside: **W8-feed** — MONARCH_TOKEN
provisioning is Colin-only (OPEN #2) and is the biggest missing proposal source for the
learner's data supply.

## 4. Unanimous core (all three designs agree — adopted without debate)

- W0 defect floor first (sux#1262/#1263/#1261).
- PDF shrink per #1187's spec verbatim, folded issue reopened, `env.IMAGES`,
  `loadBoundedPdf` guards, sux's pdf-lib only, best-effort archive leg.
- Citation-constrained hedged synthesis, 0.68 floor, `status: answered|no_match`.
- Guarded-llm `<<<DATA>>>` fencing on all ingested/retrieved material.
- Verify FHIR/#1178 state against HEAD before building.
- Radar as the single scan-assimilator; no ingest-queue contract change.
- W8 learner is FED, not built (live-verified: proposals `insights` count:0).
- All standing invariants: `phi/` fence (#613); propose-only kernel for every vault write
  the spine originates; R2=machine-CAS / Dropbox=human roles LOCKED; never-store-verbatim
  for whitelisted external material (distillates in KBs, originals as private bytes);
  "The Mac never serves the vault. sux serves the vault" (#419); oracle/advise domain
  namespacing (#1242); transit-delete-after-both-homes-confirm.

## 5. SURFACE BUDGET

Target and achieved: **ZERO new surfaces in v5 core.**

| Class | v5 count | Notes |
|---|---|---|
| New plugins / connectors / servers / workers / engines | **0** | Everything is fns inside the existing sux worker behind the one `/mcp` connector. |
| New MCP verbs | **0** | `oracle` gains an action (`ask`), `contact` gains an action (`timeline`), `get` gains a pipeline step (`shrink`), `ingest` gains routing — all existing verbs. Why the existing surface can't do it without these: `recall` returns pointers without synthesis and `oracle` today requires a caller-picked topic; neither delivers "ask anything → cited answer." An action on an existing fn is the smallest possible increment. |
| New Cloudflare bindings | **0** | AI, KV, R2, IMAGES all already wired. |
| New KV domain namespaces (`assim:*`, `phi:medical`) | data, not surface | Follow #1242 isolation. |
| New env flags | `ASSIMILATE_ENABLED` | Fail-closed, per the CROSS_SEMANTIC_ENABLED bar — a safety gate, not a surface. |
| **Contingent surface #1 — Vectorize binding `sux-corpus`** | 0 now, 1 on trigger | Why existing can't do it (the required line): KV's 25MiB value cap is a hard platform ceiling — past ~4.5k chunks/domain, writes silently drop and the index degrades to re-embed-per-request; only an external vector index removes the ceiling while adding idempotent per-vector upsert and ANN-without-full-blob-load. Added to the existing sux worker if triggered, never a second stack. Provisioning has an account-side needs-Colin step. |
| **Contingent surface #2 — CLOUDCONVERT_API_KEY** | 0 (deferred out of v5) | Why-line already on file in #1187 (Workers isolates can't run calibre/ghostscript); PDF→EPUB is delivery, not oracle. |

Explicitly REJECTED surfaces: suxos-net PR #34's parallel worker/chunker/sync stack
(duplicates `_embed.ts` and the substrate — sux + W1 does it with no new deploy); v10 L3
(tunnel/VPC/RESIDENTIAL/dind — orthogonal to recall, at-risk per its own hardening spec);
v10 L1 Iceberg lake and L0 Queues research fan-out (analytical machinery a personal corpus
doesn't need); F15 WHERE-DSL; F13 AutoRAG (ungoverned spend + broken score comparability,
§2.3); F6 Hyperdrive; any Mac-side chat-exporter daemon (§6). v10's reusable METHODOLOGY
(decision tables, parked-with-trigger non-goals, results-are-pointers, git-is-truth,
fail-closed structural trust) is adopted wholesale; its infrastructure is not — any reuse
re-derives from current HEAD, never cherry-picks the stale branch.

## 6. Explicitly out of scope

- **Portal arming** (`PORTAL_ENABLED` / portal Ph1 features) — dormant by decision;
  sequences behind retrieval landing.
- **Any release cut** — minors flow autonomously; **the v5 MAJOR cut is Colin's button**
  (§7), never the pipeline's.
- **Cut by the judge panel:**
  - Design 1's WS5 **14k-message backfill and the Vectorize binding as v5 deliverables** —
    deferred behind the triggers + W1's answer-quality telemetry, per Design 1's own
    riskiest-assumption logic (don't lock the embedding at scale before quality data
    exists).
  - Design 3's **out-of-scoping of medical and timelines — overruled** by the north star:
    for a "legal/medical/personal assistant-advisor," dropping FHIR and people/timelines
    isn't slim, it's incomplete. W7 and W8 stay in.
- **Cut unanimously (all three designs):** v10 L3/L1/L0/F15; chat-ingress automation
  (the manual toss path via `ingest` is the answer — automating iMessage/Slack/Signal
  needs a local always-on exporter daemon, violating slim-surface and inheriting
  laptop-uptime; trigger written down: revisit when Colin tosses chat excerpts more than
  ~weekly, observable in ingest logs, or when voice/ingestion epic #1184's capture work
  revives); W8 learner build (feed-only, §4); PDF→EPUB/OCR-overlay/Kindle delivery;
  decaying-confidence memory sux#1079 (revisit only after assimilation volume exists);
  org-wide git-history reset #1189 (declined, stays dead); suxos-net PR #34's parallel
  stack (mine patterns, close as superseded — OPEN #3).
- **Email-secretary buildout (#1183)** beyond the W0.2 bug fix — separate epic; W6/W7
  only leave clean proposal-queue seams.
- **R2/Dropbox role changes, sync daemons, browser-based MyChart auth** — locked/never.

## 7. Release gating

Per production-driver doctrine, three stages, in order:

> **Update 2026-07-23:** the drummer mechanism is retired (see
> `2026-07-23-standing-automation.md`). Read the two steps below as: arc-doc merge
> seeds the milestone's pipeline issues (no shepherd loop), and the cut-audit runs as
> a pipeline workflow gated on milestone-closed — same pattern, no local scheduled task.

1. **Implement — drummer seeds.** On merge of this doc, drummer `v5-implement` decomposes
   §3 into pipeline issues per the epic-decomposition design: reopen folded issues rather
   than duplicating (#1262/#1263/#1261 are filed; #1187's shrink part re-extracts from
   rollup #1192 with acceptance criteria quoted), dependency links per the §3 order,
   and the "verify against HEAD before re-implementing" warning honored per-issue. Minors
   cut autonomously as workstreams land. The drummer shepherds the drain and never cuts.
2. **Cut-audit.** When W0–W10 are drained, a post-arc audit (same drummer pattern as v4's)
   runs: W10's oracle-feel eval green is the headline criterion, plus no HIGH residue and
   the W5 metrics showing no domain in ceiling-approach. Audit reports GREEN → AMBER to
   Colin as cut-ready.
3. **Colin's button.** The v5 MAJOR cut is Colin's, after the audit — and separately,
   the `ASSIMILATE_ENABLED` flag flip is Colin's, after W10 goes green (OPEN #5). The
   pipeline auto-enables neither.

## 8. OPEN decisions (marked for Colin)

| # | Decision | Panel recommendation (default until overridden) |
|---|---|---|
| **OPEN #1** | **Lifetime mail archive timing** — is semantic recall over the full 14k-message Fastmail archive a v5 must-have (Design 1: adopt the Vectorize binding now, backfill via Workflows) or a triggered follow-on (Designs 2/3: escape hatch armed by KV-ceiling/latency triggers)? | Defer, gated on W1's answer-quality telemetry — but only Colin can say whether "scan email … the whole life" means the lifetime archive matters THIS arc, especially since the 14k "Inbox" is his lifetime archive with live mail ~1.5k. |
| **OPEN #2** | **MONARCH_TOKEN provisioning** (mint-monarch-token.py + set-secrets.sh per token-setup.md §9) — Colin-only action; the detectors it feeds are 100% built and 100% dormant without it, and it is the single biggest missing proposal source for the learner feed. | Provision when convenient; nothing in v5 blocks on it. |
| **OPEN #3** | **suxos-net PR #34 disposition** — close as superseded once W1 lands (salvage its 0.68 calibration + test corpus; leave the entangled #18 auth work behind). | Close as superseded; flagged as Colin's call since it is his open PR on another repo. |
| **OPEN #4** | **`People/<name>.md` vault convention** — materialized per-person timeline notes (Design 2: proposals-kernel writes, feeds the learner) shape Colin's vault permanently; the query-time `timeline` action (Design 1) is zero-store. | Ship the query-time verb first regardless (W8); Colin decides whether/when materialized `People/` notes enter the vault and under what naming convention. |
| **OPEN #5** | **`ASSIMILATE_ENABLED` flag flip** — the fail-closed flag gating unattended semantic writes (per the CROSS_SEMANTIC_ENABLED bar). | Flipped by Colin after the W10 E2E eval goes green — never auto-enabled by the pipeline. |
| **OPEN #6** | **Mail assimilation scope for v5** — triage-flagged mail only (W6 as specced) vs the full 1000-recent window; couples to OPEN #1 since a wider scope accelerates approach to the KV ceiling. | Triage-flagged only, monitored by W5's blob-size metrics. |

## 9. Riskiest assumption (carried forward, with its mitigation scheduled)

That recall quality is coverage-limited, not model-limited — that bge-base-en-v1.5 +
kNN + the 0.68 floor + citation-constrained synthesis is good enough for high-trust
legal/medical answering once coverage closes. If precision/recall on real medical/legal
queries proves insufficient (plausible: bge-base-en is general-domain and the 0.68
calibration was tuned on vault notes, not clinical text), the fix is a reranker or
domain-tuned embeddings — which breaks score comparability and forces a full re-embed.
That is exactly why W1 ships score-logging + thumbs from day one, why the backfill is
deferred behind that telemetry (OPEN #1), and why W5 makes the KV bet observable: the
tournament's disputed question gets answered by data before anything is locked in at scale.
