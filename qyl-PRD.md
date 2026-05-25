# Cohesive Cascade — Source-of-Truth → Analyzers → 5-Package Family → qyl MCP

> **2026-05-25 update — CR FROZEN.** User uninstalled CodeRabbit from both the
> personal account and the ANcpLua/O-ANcppLua organizations after the autofix
> bot pushed a destructive Version.props change on AL PR #174 (see Appendix 3).
> CR is **disabled until next month** when funds restored. Stage A is
> **DEFERRED**; B/C/D no longer wait on it. Re-enable runbook lives in
> Appendix 3 and at the top of `templates/coderabbit.yaml`.

**Reading guide.** Each stage unblocks the next *unless* it is marked DEFERRED.
Stages run top-to-bottom unless explicitly noted as parallel. The arrow in the
chain is _necessary_ — skipping a stage means the next stage hits unfixable
noise.

```
A. github-settings-automation       DEFERRED — CR off until funds restored
   (canonical CR + sync engine)     (Stage A unblocks itself when CR returns;
                                     unrelated to B/C/D until then)

B. renovate-config archived         one config-syndication repo, not two
       ↓                            (independent of A; can ship now)
C. ANcpLua.Analyzers 2.0.0          publish → rebundle SDK → cascade consumers
       + ANcpLua.NET.Sdk            ↑ THE load-bearing root (3 sub-stages)
       ↓                            (parallel with B/D; independent of A)
D. Qyl.OpenTelemetry.SemanticConv   publish 5 packages @ 3.0.0; runs in parallel
       3.0.0 family                  with C since registries are independent
       ↓
E. qyl MCP refactor (Phases 2-5)    Keycloak → MCP host → legacy SSE → directory
                                     submission. Needs clean baseline from C+D.
```

---

## Already shipped — sanity verify before continuing

```bash
# All five Qyl.OpenTelemetry.SemanticConventions* @ 2.0.1 on nuget.org
for p in Qyl.OpenTelemetry.SemanticConventions{,.Incubating,.SourceGeneration,.Analyzers,.Nuke}; do
  curl -fsS "https://api.nuget.org/v3-flatcontainer/$(echo $p | tr A-Z a-z)/index.json" | jq -r .versions[-1]
done
# Expect: 2.0.1 five times

# Canonical CR v2 lives at github-settings-automation/templates/coderabbit.yaml on main
gh api repos/ANcpLua/github-settings-automation/contents/templates/coderabbit.yaml --jq '.content' \
  | base64 -d | grep -E "disable_cache|auto_apply_labels" | head -5
# Expect: disable_cache: false, auto_apply_labels: false (both explicit)

# Legacy ANcpLua packages deprecated with alternatePackageId pointer
for p in ancplua.opentelemetry.conventions.nuke ancplua.opentelemetry.semanticconventions.analyzers; do
  curl -fsS "https://api.nuget.org/v3/registration5-semver1/$p/index.json" \
    | jq -r '.items[].items[].catalogEntry | "\(.id)@\(.version) deprecated=\(.deprecation != null)"' \
    | head -3
done

# Three legacy GitHub repos archived + redirected to monorepo /src
for r in Qyl.OpenTelemetry.SemanticConventions.Analyzers ANcpLua.OpenTelemetry.Conventions.Nuke ANcpLua.OpenTelemetry.SemanticConventions.Analyzers; do
  gh api "repos/ANcpLua/$r" --jq '"\(.full_name)  archived=\(.archived)"' 2>/dev/null
done

# Per-repo .coderabbit.yaml deletions live on feature branches
gh api repos/ANcpLua/ANcpLua.Analyzers/contents/.coderabbit.yaml?ref=feat/major-renumber 2>&1 | grep -q "Not Found" && echo "AL deleted ✓"
gh api repos/ANcpLua/Qyl.OpenTelemetry.SemanticConventions/contents/.coderabbit.yaml?ref=feat/3.0-renumber 2>&1 | grep -q "Not Found" && echo "QYL deleted ✓"
```

If any of these fail, fix-forward before starting Stage A.

---

## Stage A — github-settings-automation (canonical sync engine)

**Status (2026-05-25).** **Branch-protection sync is LIVE.** CR config sync
is **DEFERRED** until user re-enables CodeRabbit next month. Two independent
sub-engines:

- **A.live: Branch-protection canonical** (`templates/branch-protection.json`
  + `scripts/sync-branch-protection.sh`). Forces canonical keys onto every
  fleet repo's default branch while preserving per-repo settings. Currently
  forces `required_conversation_resolution: false` to prevent bot-uninstall
  lockouts (see Appendix 4). Wired into both jobs of
  `enforce-repo-settings.yml`. Healed 13 fleet repos on 2026-05-25 as the
  inaugural sweep.
- **A.deferred: CR config canonical** (`templates/coderabbit.yaml`). FROZEN
  banner at top of file; sync not triggered until CR reinstall. See
  Appendix 3.

**Why the split matters.** The branch-protection sync is what unblocks
fleet merges TODAY. PR #174 was stuck for hours because of an orphaned-bot
gate (Appendix 4); the canonical fix removes that class of bug fleet-wide.
That work is independent of CR being on or off.

**Prerequisites (for the live half).** None — repo is public so GHA runs
freely, and the script only uses the PAT scope that's already provisioned.

**Prerequisites (for the CR half).** GHA billing restored (already done by
public flip) + user reinstalls CR (next month).

### A1. Fix the broken sync workflow

The last `enforce-repo-settings.yml` run (`26396932904`) failed with
"recent account payments have failed or your spending limit needs to be
increased" — this is GHA-billing, not a PAT issue. `REPO_SETTINGS_PAT_USER`
secret was last rotated 2026-05-12 and is still valid.

1. **Restore GHA billing OR make g-s-a public.**
   - Public option (recommended): `gh repo edit ANcpLua/github-settings-automation --visibility public --accept-visibility-change-consequences`. The repo holds only policy YAML + sync scripts; no secrets, no internal IP.
   - Billing option: GitHub Billing & Plans → Manage spending limit → $5–$10/mo ceiling. Keeps private.
2. **Re-trigger.** `gh workflow run enforce-repo-settings.yml --repo ANcpLua/github-settings-automation --field sweep_mode=full` (use `full` first to backfill every repo; switch to `topic` for the weekly cadence afterwards).
3. **Verify completion.** `gh run watch <id>` until success. If the validate-user-PAT step fails, regenerate `REPO_SETTINGS_PAT_USER` at https://github.com/settings/personal-access-tokens with `contents:write` + `pull-requests:write` scope on every repo in `scripts/drift-policy.yaml`.

### A2. Verify canonical landed in consumer repos

Spot-check two:

```bash
for r in ANcpLua/ANcpLua.NET.Sdk ANcpLua/ANcpLua.Agents; do
  gh api "repos/$r/contents/.coderabbit.yaml" --jq '.content' \
    | base64 -d | grep -E "disable_cache|auto_apply_labels"
done
# Expect: both `disable_cache: false` and `auto_apply_labels: false`
```

### A3. Run the drift checker

`gh workflow run drift-check.yml --repo ANcpLua/github-settings-automation`. Expect zero drift after A2 succeeds — if drift surfaces, A1's sweep didn't reach those repos.

### Stage A DoD

| Gate | Verification |
|---|---|
| Sync workflow green | `gh run list --workflow enforce-repo-settings.yml --limit 1` shows `success` |
| Canonical propagated | Spot-check returns v2 values across ≥3 repos |
| Drift check clean | `drift-check.yml` reports zero divergence |

---

## Stage B — renovate-config archived into github-settings-automation

**Why second.** Eliminates the 2-repo split where one (github-settings-automation) has the sync engine + drift-check + most templates, and the other (renovate-config) has the canonical `renovate.json` + reusable `auto-merge.yml`. Drift-check is currently watching both. One source of truth is the goal.

**Prerequisites.** None — independent of Stage A's CR work. Migration is pure file-move + reference rewrite; CR being off doesn't affect Renovate.

### B1. Migrate canonical content

Move into `ANcpLua/github-settings-automation`:
- `renovate-config/renovate.json` → `templates/renovate.json` (overwrite the 118-byte placeholder)
- `renovate-config/.github/workflows/auto-merge.yml` → `templates/auto-merge.yml` (or `.github/workflows/auto-merge-reusable.yml` if reusable-workflow shape demands it)
- Anything else in renovate-config that's referenced cross-repo (check renovate-config's README header for the authoritative list)

### B2. Update consumers that referenced renovate-config

Search across the fleet:

```bash
gh search code 'renovate-config' --owner ANcpLua --owner O-ANcppLua --json repository,path \
  | jq -r '.[] | "\(.repository.name)/\(.path)"' | sort -u
```

For each hit, replace `renovate-config` references with `github-settings-automation`. Most are likely `extends` references in `renovate.json` or `uses:` references in workflow YAML.

### B3. Archive renovate-config with redirect

```bash
gh repo edit ANcpLua/renovate-config --description "ARCHIVED → moved to ANcpLua/github-settings-automation"
gh api repos/ANcpLua/renovate-config --method PATCH -F archived=true
# Set the README to a redirect notice pointing at the new home
```

### Stage B DoD

| Gate | Verification |
|---|---|
| Canonical content moved | `templates/renovate.json` + `templates/auto-merge.yml` populated in github-settings-automation |
| No consumers broken | `gh search code 'renovate-config' --owner ANcpLua` returns zero non-redirect hits |
| Repo archived | `gh repo view ANcpLua/renovate-config --json isArchived` → `true` |

---

## Stage C — ANcpLua.Analyzers 2.0.0 + ANcpLua.NET.Sdk + Consumer cascade

**Why third.** The SDK transitively bundles a per-rule severity `editorconfig` for `ANcpLua.Analyzers`. Until the SDK ships with the new AL1xxx editorconfig + the bumped analyzer pin, every SDK consumer experiences "analyzer renumber changed nothing" because their severity overrides still reference old AL0xxx rules that no longer exist.

**Prerequisites.** None — independent of Stage A's CR work. With CR off, PR reviews are now plain GitHub reviews, but CI still runs and trusted publishing still works.

### C1. Ship ANcpLua.Analyzers 2.0.0

1. **Revert the destructive CR autofix.** Commit `2fe348d "fix: apply CodeRabbit auto-fixes"` on `feat/major-renumber` bumped `<ANcpLuaAnalyzersVersion>` in `Version.props` from `1.29.4` (last-published self-reference) → `2.0.0` (the not-yet-published version this PR produces), breaking restore with NU1102. The other 4 files it touched (3 CodeFix providers + the analyzer-renumber-plan.md) are fine and should be kept. Restore line 61 of `Version.props` to `1.29.4` and commit the revert. Verify with `git show 2fe348d -- Version.props` first.

   The earlier autofix commit `5e81267` is benign — pure style fixes across 35 files. Keep it.

2. **Squash-merge PR #174** (`feat/major-renumber` → `main`) once CI passes after the Version.props revert. The final commit chain includes the renumber commit, the benign autofix commit (`5e81267`), the local-`.coderabbit.yaml`-deletion commit (`0b31305`), the destructive autofix commit (`2fe348d`), and the revert.
3. **Tag** `v2.0.0`:

   ```bash
   cd ~/RiderProjects/ANcpLua.Analyzers && git checkout main && git pull
   git tag -a v2.0.0 -m "AL renumber 2.0.0"
   git push origin v2.0.0
   ```
4. **Trusted publishing fires** on tag push via `.github/workflows/nuget-publish.yml` (OIDC `id-token: write`, no API key). Watch the workflow run.
5. **Wait for indexing.** Typically 5-15 min:

   ```bash
   until curl -fsS "https://api.nuget.org/v3-flatcontainer/ancplua.analyzers/index.json" \
     | jq -e '.versions[] | select(. == "2.0.0")' >/dev/null 2>&1; do sleep 30; done
   echo "indexed ✓"
   ```

### C2. Ship ANcpLua.NET.Sdk with bumped pin + bundled editorconfig

The SDK's working tree on `main` already has three files modified from `al-qyl-rewire`'s consumer-rewire pass:
- `src/Config/Analyzer.ANcpLua.Analyzers.editorconfig` (272 substitutions)
- `src/Build/Enforcement/VersionEnforcement.targets` (3 substitutions)
- `tools/.editorconfig` (2 substitutions)

1. **Branch + bump pin.**

   ```bash
   cd ~/RiderProjects/ANcpLua.NET.Sdk
   git checkout -b feat/al-2.0-bundling
   ```
   Edit `Version.props` and set `<ANcpLuaAnalyzersVersion>` to `2.0.0`.

2. **Commit and push.** The staged editorconfig + targets files go into this commit.

3. **Expect CI to fail.** Likely surfaces:
   - SDK's bundled generator-documentation regeneration (`scripts/generate-docs.ps1` or similar — analogous to AL's regenerated `docs/Al1200UseIsEqualTo.md` after the renumber).
   - Any test fixture or sample project that hard-codes old AL0xxx IDs.
   - Any `.globalconfig` the SDK ships that still references old IDs (separate from the bundled `editorconfig` already updated).
   - Drift between updated `editorconfig` content and what `drift-check.yml` expects.

4. **Fix inline, force-push as needed.** Authorized.

5. **Merge** once CI is green.

6. **Tag the SDK's next major** (likely `v3.x.x` — analyzer pin bump is a breaking-change pull-through for any consumer with AL severity overrides). Trusted publishing fires.

7. **Wait for SDK indexing.**

### C3. Consumer cascade in parallel

Once C2's SDK version is indexed, open one PR per consumer. Most consumers already have their per-repo editorconfig updates staged on `main` from `al-qyl-rewire` — package those + the pin bumps into each PR.

| Repo | Shape | Branch suggestion |
|---|---|---|
| `qyl` | 32 `.editorconfig` + 24 `.globalconfig` AL ID rewrites already staged + bump `ANcpLuaNETSdkVersion` (and any direct `ANcpLuaAnalyzersVersion`) | branch off the existing `chore/qyl-mcp-destruction-pass-2026-05-25` or a fresh branch |
| `ErrorOrX` | 5 `.editorconfig` rewrites already staged + pin bump | `chore/al-2.0-cascade` |
| `TourPlanner` | 1 `.editorconfig` line deleted + pin bump | `chore/al-2.0-cascade` |
| `ANcpLua.Roslyn.Utilities` | 1-line XML-doc comment fix in `AnalyzerTest.cs` + optional pin bump | `chore/al-2.0-cascade` |

Once all four merge, every repo in the fleet emits AL1xxx diagnostic IDs with the correct severity overrides — Stage C is closed.

### Stage C DoD

| Gate | Verification |
|---|---|
| AL 2.0.0 indexed | `curl … ancplua.analyzers/index.json` lists `2.0.0` |
| SDK published | New SDK version indexed on nuget.org with `ANcpLuaAnalyzersVersion = 2.0.0` |
| Consumers merged | All 4 PRs merged, CI green |
| End-to-end smoke | Build `qyl` against the new SDK, verify AL1xxx diagnostics fire with the expected severities (not the old AL0xxx) |

---

## Stage D — Qyl.OpenTelemetry.SemanticConventions 3.0.0 (5-package family)

**Why parallel with C.** The QYL#### analyzer registry is independent of the AL#### registry — different package id, different prefix, no Roslyn-level collision. D can ship the same day as C.

**Prerequisites.** None — independent of Stage A's CR work. QYL PR #2 is currently green and mergeable; this stage can ship today.

### D1. Merge + publish

1. **Squash-merge PR #2** (`feat/3.0-renumber` → `main`) in `ANcpLua/Qyl.OpenTelemetry.SemanticConventions`.
2. **Tag** `v3.0.0`:

   ```bash
   cd ~/RiderProjects/Qyl.Opentelemetry.SemanticConventions && git checkout main && git pull
   git tag -a v3.0.0 -m "QYL renumber 3.0.0"
   git push origin v3.0.0
   ```
3. **Trusted publishing fires** for all five packages.
4. **Wait for indexing.** All five at `3.0.0`.

### D2. Optional: unlist 2.0.1 of `.Analyzers`

The renumber means `Qyl.OpenTelemetry.SemanticConventions.Analyzers@2.0.1` has different DiagnosticIds than `3.0.0`. To discourage consumers from pinning the orphan intermediate:

```bash
dotnet nuget delete Qyl.OpenTelemetry.SemanticConventions.Analyzers 2.0.1 \
  --api-key "$NUGET_API_KEY" --source https://api.nuget.org/v3/index.json --non-interactive
```

The other four packages (`Stable`, `.Incubating`, `.SourceGeneration`, `.Nuke`) keep `2.0.1` listed — they're stable intermediates with no breaking-change.

### Stage D DoD

| Gate | Verification |
|---|---|
| All 5 indexed at 3.0.0 | Five `curl` checks |
| `.Analyzers@2.0.1` unlisted (optional) | nuget.org page shows version as unlisted |
| Dogfood loop intact | `./build.sh VerifyAttributesHash` green on the merged `main` (attribute manifest hash unchanged by the renumber) |

---

## Stage E — qyl MCP refactor (Phases 2-5)

**Why last.** All preceding stages have closed: SDK ships AL 2.0.0 with the correct bundled editorconfig, QYL 3.0.0 family is on nuget.org, qyl's baseline is clean. Now the MCP/Keycloak refactor can run without baseline noise.

**Prerequisites.** Stages C and D complete. qyl is on a working-tree branch (currently `chore/qyl-mcp-destruction-pass-2026-05-25` with PR #369 open).

Continue committing to the existing branch; prefer one PR per sub-phase (E1, E2, E3, E4 as separate merges).

### E1 — Phase 2: Keycloak OIDC discovery + PKCE + /auth/* endpoints

#### E1.a (Task #33) — KeycloakClient + PKCE state store

DoD:
- `KeycloakClient.GetDiscoveryDocumentAsync(ct)` returns parsed `authorization_endpoint`, `token_endpoint`, `jwks_uri`, `end_session_endpoint`, `issuer` from `<QYL_KEYCLOAK_AUTHORITY>/.well-known/openid-configuration`.
- Discovery doc cached 1 hour; refresh on signing-key validation failure.
- `IPkceStateStore.StoreAsync(state, codeVerifier, tenantId, clientRedirectUri, nonce, ttl)` writes a `mcp_pkce_state` row (Phase 1's table).
- `IPkceStateStore.ConsumeAsync(state)` returns the row exactly once — second call returns `null` (single-use).
- Rows past `expires_at` return `null`.
- Background cleanup deletes expired rows on the same 5-min `PeriodicTimer` as `McpTokenCleanupService`.
- Unit test asserts single-use, TTL expiration, consume-then-cleanup behavior.

#### E1.b (Task #34) — `GET /auth/authorize`

DoD:
- Returns `302 Found` with `Location` pointing at Keycloak's `authorization_endpoint`.
- `Location` query carries: `response_type=code`, `client_id`, `redirect_uri` (collector callback), `scope=openid profile email offline_access`, `state` (random), `code_challenge=S256(verifier)`, `code_challenge_method=S256`, `nonce` (random).
- `state` is base64url-encoded 32 random bytes (matches opaque-token entropy).
- `code_verifier` (43-128 chars, URL-safe) stored in `mcp_pkce_state` **before** the redirect is returned (no race).
- Validates `redirect_uri` against an allowlist (per-tenant or `QYL_OAUTH_ALLOWED_REDIRECTS` env var). Unknown URIs → `400`.
- Unit test parses `Location` header + asserts every required query param. Negative test for unknown `redirect_uri`.

#### E1.c (Task #35) — `GET /auth/callback`

DoD (executes in order):
1. `IPkceStateStore.ConsumeAsync(state)` — `400` if not found or expired.
2. POST to Keycloak `token_endpoint` with `grant_type=authorization_code`, `code`, `code_verifier`, `redirect_uri` — `502` if Keycloak unreachable, `401` if rejected.
3. Validate `id_token` JWT: signature against JWKS (refreshable, cached), `aud == QYL_KEYCLOAK_AUDIENCE`, `iss == discovery.issuer`, `nonce` matches state row, `exp > now`. Any failure → `401`.
4. Encrypt `refresh_token` via Phase 1's `ITokenEncryption.Encrypt`.
5. `IMcpTokenStore.CreateAsync` with `userId = id_token.sub`, `tenantId` from state, `scopes` from token response, `refresh_expires_at = now + refresh_expires_in`.
6. Return `302 Found` to `<clientRedirectUri>#token=<opaque>&expires_at=<...>` (token in URL fragment, never query — fragments aren't logged by proxies).

- Opaque token never logged, never in error responses, never persisted anywhere except this redirect.
- Integration test against `Testcontainers.Keycloak` walks the full happy path + negative tests for each failure case (expired state, replayed state, wrong audience, wrong nonce, tampered code).

#### E1.d (Task #36) — `/auth/refresh` + `/auth/revoke`

DoD:
- `POST /auth/refresh` with `Authorization: Bearer <opaque>`:
  - Looks up via `IMcpTokenStore.GetByOpaqueTokenAsync` (constant-time hash compare).
  - Decrypts refresh token, POSTs to Keycloak with `grant_type=refresh_token`.
  - On success: encrypts the new refresh token, calls `IMcpTokenStore.UpdateRefreshAsync`.
  - Returns `{ "expires_at": "..." }`. Never returns the underlying Keycloak token.
  - On Keycloak failure (refresh expired/upstream revoked): `IMcpTokenStore.RevokeAsync` + `401`.
- `POST /auth/revoke` with Bearer:
  - Calls Keycloak `revocation_endpoint` with `token=<keycloak refresh>` to invalidate upstream.
  - `IMcpTokenStore.RevokeAsync` (sets `revoked_at`).
  - Returns `204` even if upstream revoke fails (idempotent locally).
- Integration tests: refresh-succeeds, refresh-fails-after-upstream-revoke, revoke-then-mcp-call-rejects.

#### E1.e (Task #37) — Integration tests + commit Phase 2

DoD:
- `Testcontainers.Keycloak v4.12` (the Java image, **not** Quarkus — different admin API shape) boots in CI in <20s with a pre-imported realm JSON (`tests/qyl.collector.integration.tests/Resources/qyl-test-realm.json`).
- Realm has: one test client with PKCE required, one test user (`alice@test`), one tenant-claim mapper.
- End-to-end test: `HttpClient` walks the full browser flow with cookies, asserts opaque token shape + `/auth/refresh` works + cross-tenant rejection.
- All Phase 1 tests still pass (no regressions).
- `dotnet build qyl.slnx` → 0 errors.
- 1-N commits for Phase 2 pushed to the branch.

#### E1 overall — Phase 2 DONE gate

| Gate | Verification |
|---|---|
| Build | `dotnet build qyl.slnx --nologo /clp:ErrorsOnly` → 0 errors |
| Unit tests | xUnit project green (PKCE state, KeycloakClient discovery, `/auth/authorize` shape) |
| Integration tests | `Testcontainers.Keycloak` happy path + 5 negative paths |
| Manual smoke | On running collector + Keycloak, browser to `/auth/authorize?tenant=demo&redirect_uri=…` returns token in URL fragment |
| Security audit | No opaque token in logs (`grep -ri 'opaque\|token' artifacts/ | wc -l` baseline established); `code_verifier` never appears in any log |
| Deploy-readiness | `QYL_TOKEN_ENCRYPTION_KEY` set on Railway collector service (see Railway section below) |
| Phase 1 reconciliation | Any Phase-1-surface bugs surfaced (`IMcpTokenStore`, `ITokenEncryption`) get fixes in Phase 2's commits |
| Git | Branch pushed, PR description updated |

#### Railway deployment piece (executed by you, interactive auth)

`QYL_TOKEN_ENCRYPTION_KEY` must be set on the Railway `qyl-collector` service before Phase 2 lands in prod — otherwise the collector throws `InvalidOperationException` the moment the cleanup service or any `/auth/*` endpoint resolves `ITokenEncryption`.

```bash
railway login
railway link --service qyl-collector
railway variables --set QYL_TOKEN_ENCRYPTION_KEY=$(openssl rand -base64 32)
```

### E2 — Phase 3: MCP host (`/mcp/{tenant}`)

#### E2.a (Task #38) — 3A: Make `qyl.mcp` library-consumable

DoD:
- `services/qyl.mcp/qyl.mcp.csproj` consumable as a library (existing Exe wrapper for stdio dev remains; both ship from the same assembly).
- New `<ProjectReference>` in `services/qyl.collector/qyl.collector.csproj` pointing at `services/qyl.mcp`.
- Collector calls `QylToolManifest.RegisterTools(builder, skills, jsonOptions)` successfully — same registration path `qyl.mcp` itself uses.
- `services/qyl.mcp/Program.cs` stdio entry point unchanged — verified by running `qyl-mcp` locally.
- `dotnet build qyl.slnx --nologo /clp:ErrorsOnly` → 0 errors.
- All `tests/qyl.mcp.tests/` tests pass.

#### E2.b (Task #39) — 3B: `/mcp/{tenant}` endpoint with Bearer auth

DoD:
- Collector calls `AddMcpServer().WithHttpTransport(o => { o.Stateless = true; ... })`.
- `app.MapMcp("/mcp/{tenant}")` registered on the `WebApplication`.
- New `BearerOpaqueTokenAuthenticationHandler` (or filter) on the route:
  - Parses `Authorization: Bearer <opaque>`.
  - Calls `IMcpTokenStore.GetByOpaqueTokenAsync` (constant-time hash compare from Phase 1).
  - Missing/malformed → `401`. Not-found/expired/revoked → `401`. Path tenant ≠ token tenant → `403`.
- On success, `HttpContext.User` populated with `ClaimsPrincipal` carrying:
  - `ClaimTypes.NameIdentifier = user_id`
  - Custom claim `qyl.tenant_id = tenant_id`
  - Multiple `Scope` claims expanded from the `scopes` column
- `GET /mcp/{tenant}/.well-known/oauth-protected-resource` returns RFC 9728 Protected Resource Metadata (`resource`, `authorization_servers`, `scopes_supported`, `bearer_methods_supported`).
- Integration test: MCP `initialize` with (a) no Bearer → `401`, (b) revoked Bearer → `401`, (c) wrong-tenant Bearer → `403`, (d) valid Bearer → `200` + `tools/list` returns expected tools.

#### E2.c (Task #40) — 3C: Per-tenant tool scoping via ClaimsPrincipal

DoD:
- `ConfigureSessionOptions` callback wired (per `mcp-csharp-sdk-1.3.0` skill `stateless.md` — runs per request in stateless mode).
- Callback reads `qyl.tenant_id` claim and configures a per-session `QylScope` for the tool invocation pipeline.
- Tools that read `QylScope` (via `ScopingDelegatingHandler` on the outbound `CollectorClient`) inject `qyl.tenant_id` as a request header to the collector.
- `ClaimsPrincipal` parameter auto-injected into any tool method declaring it (verified per `mcp-csharp-sdk-1.3.0` skill `identity.md`).
- Integration test: two tokens (tenants A and B), each calls `qyl.list_services` — results disjoint by `service.name` (no cross-tenant leakage even with co-mingled DuckDB data).

#### E2.d (Task #41) — 3D: Integration tests + commit Phase 3

DoD:
- End-to-end integration test combines Phase 2's `Testcontainers.Keycloak` + the collector running in-process:
  - Browser-shape flow drives `/auth/authorize` → Keycloak login → `/auth/callback` → captures opaque token from URL fragment.
  - MCP client connects to `/mcp/<tenant>` with Bearer.
  - `tools/list` returns expected qyl tool surface.
  - At least 3 read-only tool calls succeed (`qyl.list_services`, `qyl.list_error_issues`, `qyl.health`).
  - Token revoke via `/auth/revoke` → next MCP call returns `401`.
- Cross-tenant isolation test (per E2.c) included.
- All Phase 1 + Phase 2 tests still pass.
- `dotnet build qyl.slnx` → 0 errors.
- Phase 3 commits pushed.

#### E2 overall — Phase 3 DONE gate

| Gate | Verification |
|---|---|
| OAuth Protected Resource Metadata | `GET /mcp/<tenant>/.well-known/oauth-protected-resource` returns RFC 9728 shape |
| Real MCP client works | Claude Desktop config pointing at `https://collector/mcp/<tenant>` lists tools + calls one |
| Tenant isolation | Integration test proves tenant A token cannot read tenant B data |
| Stateless mode | No `Mcp-Session-Id` header required; horizontal scaling has no sticky-session need |
| No stdio regression | `tests/qyl.mcp.tests/` all pass |
| Phase 1+2 reconciliation | Bugs surfaced by Phase 3 integration tests fixed in Phase 3 commits, not patched on top |

### E3 — Phase 4: Legacy SSE dual endpoint

#### E3.a (Task #42) — Enable legacy SSE alongside Streamable HTTP

DoD:
- `WithHttpTransport` options block carries both:
  - `Stateless = false` (SSE requires stateful per `mcp-csharp-sdk-1.3.0` skill `stateless.md`).
  - `EnableLegacySse = true` inside a `#pragma warning disable MCP9004 … restore` block, with a `// Client migration window — remove when telemetry shows <X% legacy traffic` comment.
- `MapMcp("/mcp/{tenant}")` serves Streamable HTTP at the root of that route.
- `/mcp/{tenant}/sse` exposes the long-lived SSE GET endpoint.
- `/mcp/{tenant}/message?sessionId=...` accepts client POSTs on the same session.
- Phase 3's Bearer auth + tenant scoping enforced on **both** transports — no auth bypass through legacy `/sse`.
- Confirmed simultaneous operation: a Streamable HTTP client and a legacy SSE client connect to the same route at the same time without interference.
- Phase 1 cleanup service + Phase 2 OAuth flow unaffected by the stateful switch (they don't depend on transport mode).
- Integration test: opens SSE with Bearer, sends `tools/list`, receives response. Separately, a Streamable HTTP request on the same route returns the same `tools/list` result.
- Backpressure note added to `services/qyl.collector/README.md`: SSE returns `202` immediately for POSTs (no HTTP-level backpressure on handlers — see `mcp-csharp-sdk-1.3.0` skill `transports.md`). Recommendation to add ASP.NET Core rate limiting if abuse becomes a concern.
- `dotnet build qyl.slnx` → 0 errors.

#### E3 overall — Phase 4 DONE gate

| Gate | Verification |
|---|---|
| Both transports live | Integration tests for Streamable HTTP AND legacy SSE on the same `/mcp/{tenant}` |
| Auth on both | No path that skips the Bearer check |
| No Phase 3 regression | Existing Streamable HTTP integration tests still pass |
| Migration doc | `services/qyl.collector/README.md` or `docs/connector/MCP-TRANSPORT-MIGRATION.md` explains when the SSE shim will be removed (e.g., "when <1% of MCP traffic uses SSE for 30 days") |
| Telemetry | Span `mcp.transport` attribute distinguishes `streamable-http` vs `sse` traffic so the migration is measurable |

### E4 — Phase 5: Directory submission

#### E4.a (Task #43) — 5A: Tool annotations audit

DoD:
- Every `[McpServerTool]` method in `services/qyl.mcp/Tools/` has:
  - `Title = "..."` (human-readable title for the directory listing UI).
  - Exactly one of `ReadOnly = true` (query-only) OR `Destructive = true` (side effects: `qyl.generate_fix`, `qyl.approve_fix_run`, `qyl.reject_fix_run`).
- Per-tool audit table committed at `docs/connector/tool-annotations-audit.md` — each row: tool name × annotation × audit-rationale.
- Borderline tools (where Destructive vs ReadOnly is debatable) default to `Destructive = true` (safer for review) with rationale documented.
- `dotnet build qyl.slnx` → 0 errors, no `MCP*` warnings.
- All `tests/qyl.mcp.tests/` pass (annotations are additive).
- `mcp-csharp-sdk-1.3.0` skill `tools.md` Title + hint conventions matched exactly.

#### E4.b (Task #44) — 5B: Privacy policy + connector manifest

DoD:
- `docs/connector/privacy-policy.md` exists AND is hosted at a stable public URL (e.g. `https://qyl.ai/connector/privacy`) returning `200 OK`.
- Privacy policy covers:
  - Data accessed: traces, logs, error issues, metrics, GenAI conversations from the qyl-collector instance — explicit list, no broader.
  - Data flow: Claude Desktop → qyl-collector → DuckDB. No third parties.
  - Retention: references existing DuckDB retention policy (TTL on each table).
  - Token lifecycle: opaque MCP token TTL (matches Keycloak refresh expiry), refresh, revocation behavior.
  - User deletion: how user revokes consent (`/auth/revoke`) and what happens to their tokens (deleted after 7-day grace per Phase 1 cleanup service).
- Connector submission manifest at `docs/connector/manifest.{yaml|json}` per `claude.com/docs/connectors/building/submission.md`, populated with:
  - `name`, `version`, `description`, `long_description` (markdown)
  - `server_url` pattern (with `{tenant}` placeholder)
  - `oauth_authorization_endpoint`, `oauth_token_endpoint` (or rely on Protected Resource Metadata auto-discovery from E2.b)
  - `scopes_required` (matches what `/auth/authorize` actually requests)
  - `privacy_policy_url` (the stable URL above)
  - logo (small + large PNG variants in `docs/connector/assets/`)
  - screenshots (≥3 PNGs showing real qyl tool calls in Claude Desktop)
- All referenced URLs (privacy policy, logo, screenshots) actually return `200 OK` from the public internet.
- Manifest validated against Anthropic's submission schema if available (else: manual inspection against `submission.md` examples).

#### E4.c (Task #45) — 5C: Submit to Connectors Directory

DoD:
- Submission form completed and submitted to Anthropic per `claude.com/docs/connectors/building/submission.md`.
- Acknowledgment received from Anthropic review queue (email or dashboard).
- Review feedback addressed — one or more iterations of fix → resubmit:
  - Each round of feedback gets its own commit referencing the reviewer's request.
  - Phase 1-4 surfaces can be touched if review demands (per the cascade rule).
- Connector accepted and listed in the public Anthropic Connector Directory.
- Public listing URL captured in `docs/connector/STATUS.md` with submission date + acceptance date.
- Internal announcement: connector is now a customer-visible product surface — link posted in team channels + added to `services/qyl.collector/README.md` "Public Connectors" section.

#### E4 overall — Phase 5 DONE gate

| Gate | Verification |
|---|---|
| Public listing | qyl appears in the Anthropic Connector Directory at a stable URL |
| Net-new user flow | A user with no prior qyl access can: find the listing → click Connect → see qyl tools in their Claude conversation → make a real tool call successfully |
| Customer docs | Setup docs published and linked from the directory listing (how to point Claude at a qyl collector, env-var reference, troubleshooting) |
| Tool annotations | 100% of `[McpServerTool]` methods carry Title + ReadOnly/Destructive — verifiable by analyzer or grep |
| Privacy compliance | Privacy policy URL live, manifest references it, Anthropic review accepted |

---

## Appendix 1 — Critical state to remember through compaction

- `NUGET_API_KEY` is exported in the terminal shell (rotated 2026-05-24, ~3-month expiry). Stages C/D use OIDC trusted publishing so the key isn't needed for the package pushes — only `dotnet nuget unlist` and `dotnet nuget deprecate` operations need it.
- The `enforce-repo-settings.yml` workflow is the only path canonical CR config updates take to reach consumer repos. Currently DEFERRED — see Appendix 3.
- The CR autofix bot used to push commits to PR branches even while the formal CR review POST was failing. With CR uninstalled (2026-05-25), this is no longer a live risk — but if CR is re-enabled, the lesson stands: always verify autofix commits before merge with `git show <sha>`.
- Phases 1-4 inside Stage E can be adjusted if Phase 5 (directory submission review) demands changes — this PRD is the source of truth, update it inline if review feedback shifts requirements.

## Appendix 2 — Already shipped, do not re-do

- ✅ Canonical CR config v2 merged into `ANcpLua/github-settings-automation` (PR #16) — content is in `templates/coderabbit.yaml`.
- ✅ `Qyl.OpenTelemetry.SemanticConventions{,.Incubating,.SourceGeneration,.Analyzers,.Nuke}` published on nuget.org at `2.0.1`.
- ✅ Legacy packages deprecated with `alternatePackageId` pointer: `ANcpLua.OpenTelemetry.Conventions.Nuke@0.1.0`, `ANcpLua.OpenTelemetry.SemanticConventions.Analyzers@2.0.0`.
- ✅ Three legacy repos archived + redirected to `https://github.com/ANcpLua/Qyl.OpenTelemetry.SemanticConventions/tree/main/src`: `Qyl.OpenTelemetry.SemanticConventions.Analyzers`, `OpenTelemetry.Conventions.Nuke`, `opentelemetry.semanticconventions.analyzers`.
- ✅ Per-repo `.coderabbit.yaml` files deleted from `ANcpLua.Analyzers` (commit `0b31305`) and `Qyl.OpenTelemetry.SemanticConventions` (commit `0357055`) — canonical now owns CR config (when CR returns).
- ✅ Monorepo root README's "Donation story" section renamed to "Upstream path" (commit `a950400` on `feat/3.0-renumber`).

---

## Appendix 3 — CodeRabbit freeze (2026-05-25 → next month)

**Status.** CR uninstalled from both personal account and ANcpLua /
O-ANcppLua orgs. No PR reviews, no autofix commits, no chat. The canonical
`templates/coderabbit.yaml` is intentionally not being synced.

**Trigger.** AL PR #174 CR autofix bot pushed commit `2fe348d` that bumped
`<ANcpLuaAnalyzersVersion>` in `Version.props` from `1.29.4` (the
deliberate "last-PUBLISHED" self-reference) to `2.0.0` (the not-yet-published
version the PR PRODUCES). That broke `dotnet restore` with NU1102 because
ANcpLua.Analyzers 2.0.0 doesn't exist on nuget.org yet. The autofix bot
conflated `VersionPrefix` (the version BUILT) with `ANcpLuaAnalyzersVersion`
(the version CONSUMED for self-injection via the SDK's GlobalPackageReference)
despite the in-file comment on `Directory.Build.props` warning against
exactly that pattern.

**What remains intact.**

- `templates/coderabbit.yaml` v2 (with retry-loop fix + autofix recipes) —
  frozen, with a banner at the top documenting the freeze + re-enable runbook.
- Per-repo `.coderabbit.yaml` deletions on AL `feat/major-renumber` and
  QYL `feat/3.0-renumber` — these are still correct; canonical owns the
  config (when CR returns).
- The github-settings-automation sync engine — code unchanged; it just
  isn't being triggered.

**Re-enable runbook (when funds restored).**

1. Confirm GHA billing is restored for ANcpLua org (or flip g-s-a to
   public visibility — recommended; no secrets in repo).
2. Reinstall the CodeRabbit GitHub App on personal account + on
   ANcpLua / O-ANcppLua orgs.
3. Open `templates/coderabbit.yaml` and decide on autofix posture:
   - **Tighten** by adding `path_filters: ['!**/Version.props', '!**/Directory.Build.props', '!**/Directory.Packages.props']` under `reviews:` so CR cannot touch version-infrastructure files.
   - **OR neutralize** by deleting the `finishing_touches.custom` recipes — keeps CR comment-only, no auto-pushed commits.
   - **OR downgrade** to a CR plan tier without autofix.
4. Delete the FROZEN banner block at the top of `templates/coderabbit.yaml`
   (the comment region between the schema directive and the original
   "Canonical CodeRabbit baseline" line).
5. Re-trigger propagation:
   `gh workflow run enforce-repo-settings.yml --repo ANcpLua/github-settings-automation --field sweep_mode=full`.
6. Spot-check two consumer repos for v2 values:
   `gh api repos/ANcpLua/ANcpLua.NET.Sdk/contents/.coderabbit.yaml --jq '.content' | base64 -d | grep -E "disable_cache|auto_apply_labels"` should return both `false`.
7. Run `gh workflow run drift-check.yml --repo ANcpLua/github-settings-automation` and verify zero drift.

**Independence note.** Stages B, C, D, and E do NOT depend on CR returning.
Without CR, PR reviews are plain GitHub reviews; CI still runs; trusted
publishing still works. The only thing missing is the conversational
"@coderabbitai" interface on PRs and the autofix recipes. Cascade work
proceeds without them.

---

## Appendix 4 — Orphaned-bot-thread lockout + canonical branch protection

**Incident (2026-05-25).** After CR was uninstalled, AL PR #174 became
unmergeable with the message `the base branch policy prohibits the merge`.
Root cause: `ANcpLua/ANcpLua.Analyzers` had branch protection on `main`
with `required_conversation_resolution: true`, and PR #174 carried 40
open CR-bot review threads (per the autofix commit message: "Fixed 35
file(s) based on 40 unresolved review comments"). With the CR bot no
longer installed, none of those threads could be marked resolved by the
bot itself, and no human had triaged them — so the merge stayed blocked.

A fleet sweep confirmed every active ANcpLua/* repo with branch
protection had the same `conv_resolution: true` setting, meaning **the
lockout pattern was systemic, not local to one repo**. Any future
bot-reviewer install + uninstall cycle would reproduce the lockout.

**Algorithmic fix.** Added a new canonical sub-engine to
`github-settings-automation`:

- `templates/branch-protection.json` — declares the keys to force
  fleet-wide. Currently only `required_conversation_resolution: false`
  is the headline override; `allow_force_pushes` / `allow_deletions` /
  `lock_branch` are also pinned `false` as universal safety defaults.
- `scripts/sync-branch-protection.sh` — GET-merge-PUT pattern that
  forces the canonical keys while preserving every other per-repo
  protection setting (CI checks, review requirements, restrictions).
  Skips repos with no protection (heal-only, never auto-enable).
- New step in both jobs of `.github/workflows/enforce-repo-settings.yml`
  ("Sync branch protection") that calls the script for every fleet
  target.

**Inaugural sweep (2026-05-25).** Healed 13 fleet repos:
ANcpLua.Analyzers, ANcpLua.NET.Sdk, ANcpLua.Roslyn.Utilities,
ANcpLua.Agents, ErrorOrX, dotcov, TourPlanner, TourPlanner-Angular,
Paperless, typespec-otel-semconv, ancplua-claude-plugins, ancplua-docs,
ANcpLua.OpenTelemetry.SemanticConventions.Analyzers. All flipped from
`conv_resolution: true` → `false`. Qyl.OpenTelemetry.SemanticConventions
has no branch protection at all (new repo) and was skipped per the
heal-only rule.

**Why this isn't scope creep.** The original `enforce-repo-settings.yml`
deliberately owned `.coderabbit.yaml`, autofix workflow, auto-merge
workflow, and `delete_branch_on_merge` — config artifacts that drift if
left to humans. Branch protection is the same shape of artifact (it
drifts, it's per-repo, the rules should be the same fleet-wide) and now
lives in the same engine.

**Future canonical-template extensions.** Add a key to
`templates/branch-protection.json` and the sync engine forces it on the
next sweep. Candidate next additions when there's appetite:
- `required_status_checks: { strict: false, contexts: ["build"] }` — would
  force CI-must-pass everywhere. Needs convention check first (not every
  repo has a `build` job name).
- `enforce_admins: false` — already the de-facto state but worth pinning
  so an accidental UI flip doesn't lock the user out.

**Re-trigger sweep (any time):** GHA billing is now restored (g-s-a is
public), so:
`gh workflow run enforce-repo-settings.yml --repo ANcpLua/github-settings-automation --field sweep_mode=full`.

---

## Appendix 5 — Canonical NuGet publish workflow (third sync target)

**Incident (2026-05-25).** Stage D's plan stated "Trusted publishing fires
for all five packages" on tagging `v3.0.0`. Reality: QYL had no
`nuget-publish.yml` workflow at all. The tag push was a silent no-op. All
prior QYL versions (1.x, 2.x) had been published manually via local
`dotnet nuget push`. The PRD text was wishful copy-paste from AL's setup.

The deeper issue: every time the team added a new publishable repo, the
publish workflow had to be re-authored by hand. That's exactly the
per-repo drift the sync engine exists to eliminate.

**Algorithmic fix (third canonical sync target).** Added to
`github-settings-automation`:

- `templates/nuget-publish.yml` — canonical workflow. Triggers on `v*`
  tag push or `workflow_dispatch` with a `version` input. Discovers the
  repo's `.slnx`/`.sln`, packs the whole solution, pushes every
  `.nupkg` to nuget.org + GitHub Packages with `NUGET_API_KEY`.
- `scripts/sync-nuget-publish.sh` — seeds the workflow into target
  repos. Respects the `CANONICAL-DEPARTURE` opt-out marker (for repos
  with bespoke publish flows, e.g. AL's `PackageId=Dummy` trick).
  Skips non-.NET repos (no `global.json`).
- `scripts/sync-nuget-secret.sh` — propagates `NUGET_API_KEY` from
  g-s-a's own repo secret onto each opted-in target. Rotation: rotate
  once on g-s-a, fleet picks it up on the next sweep.
- `scripts/drift-policy.yaml` — new top-level `nuget_publishers:` list
  defines opt-in. v1 entry: `ANcpLua/Qyl.OpenTelemetry.SemanticConventions`.
  Apps (TourPlanner, Paperless, etc.) excluded by design. AL excluded
  pending Dummy-trick removal.
- `.github/workflows/enforce-repo-settings.yml` — new
  "Sync nuget-publish.yml + NUGET_API_KEY" step in both enforce-user
  and enforce-org jobs.

**Prerequisites for the live sync.** g-s-a needs `NUGET_API_KEY` as a
repo secret on g-s-a itself (so the workflow can propagate it):

```bash
gh secret set NUGET_API_KEY -R ANcpLua/github-settings-automation --body "$NUGET_API_KEY"
```

**Live first run (QYL 3.0.0 publish).** After the algorithm lands:

1. Sync workflow file to QYL: either manually
   (`scripts/sync-nuget-publish.sh ANcpLua/Qyl.OpenTelemetry.SemanticConventions`)
   or via the enforce-repo-settings sweep.
2. Set NUGET_API_KEY on QYL: either via the sync (g-s-a secret →
   target secret) or manually
   (`gh secret set NUGET_API_KEY -R ANcpLua/Qyl.OpenTelemetry.SemanticConventions --body "$NUGET_API_KEY"`).
3. Trigger publish:
   `gh workflow run nuget-publish.yml -R ANcpLua/Qyl.OpenTelemetry.SemanticConventions --field version=3.0.0`.
4. Verify all 5 packages indexed on nuget.org at 3.0.0.

**Future extensions.**
- OIDC trusted publishing: when `NUGET_USER` secret is set on a target
  AND the package has a Trusted Publisher policy configured on nuget.org,
  swap the API-key auth in the workflow for `NuGet/login@v1`. Single
  workflow edit propagates to every publisher on the next sweep.
- Migrate AL onto canonical: requires removing AL's `PackageId=Dummy`
  trick (set the real PackageId in the csproj directly), then dropping
  the `CANONICAL-DEPARTURE` marker from AL's workflow if any. After
  that, AL's bespoke `nuget-publish.yml` can be replaced by the
  canonical template.

**Why this isn't scope creep.** Same shape of artifact as
`.coderabbit.yaml` (per-repo, drift-prone, conceptually identical
across the fleet) — belongs in the same engine. The `nuget_publishers:`
opt-in list keeps the blast radius small (publishers only) while the
sync engine treats it the same as every other canonical.
