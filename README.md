# Collaborative Review for rightbrained.cloud — Setup Guide

## What's in this folder

| File | Purpose |
|---|---|
| `review.html` | The gated review page. Runs standalone in mock mode right now — open it and try the full loop (sign in as reviewer, suggest an edit, sign in as owner, approve it). |
| `framework.json` | Your framework as structured data: 13 disciplines, 164 cells extracted directly from the live site's `data-id`/`data-tip` attributes — real tooltips, the site's own stable cell IDs, correct tactical/strategic zones, plus `links` (predecessor/successor) and `how` fields reserved for the future dimension. |
| `extracted.json` | Raw extraction from the live DOM (kept as a reference snapshot). |

**Before going live:** the predecessor/successor relations aren't in `framework.json` yet — they live in your page's JS, not in cell attributes. Send me the page source (or the relation map) and I'll merge them into `links`.

## Architecture

```
Public page (static)          Review page (gated)              n8n
rightbrained.cloud   ←reads─  review.rightbrained.cloud  ─POST→  webhooks
        ↑                                                          │
   framework.json  ←──────── publish on approve ──────────────────┤
                                                                   │
                                              DB (Supabase/NocoDB/Airtable)
                                              suggestions + allowlist + sessions
```

The public page and review page both render from the same `framework.json`. Reviewers never edit the page — they submit suggestions; approval merges into the JSON and republishes.

## n8n workflows (4 total)

### 1. Auth — `GET /webhook/auth/linkedin`
1. Redirect to LinkedIn OIDC (`https://www.linkedin.com/oauth/v2/authorization`) with scopes `openid profile email`. Create the app at developer.linkedin.com and enable the **"Sign In with LinkedIn using OpenID Connect"** product — it's self-serve, no partner review.
2. Callback node exchanges the code, calls `https://api.linkedin.com/v2/userinfo` → `{name, email, picture}`.
3. **Allowlist check** (the actual gate): look up the email in your `invitees` table. Miss → friendly "request access" page that notifies you. Hit → issue a session: signed JWT in an HttpOnly cookie (or a random token stored in a `sessions` table), then redirect to `review.html`.
4. `review.html` change for live mode: set `CONFIG.mockMode = false`; the Sign in button then redirects to this webhook.

### 2. Submit — `POST /webhook/framework/suggest`
Validate session → insert row into `suggestions` (cellId, type, proposedLabel, proposedTooltip, comment, user, ts, status=pending) → notify you (email or Slack) with the diff and one-click approve/reject links (n8n Wait-for-Webhook or links to workflow 4).

### 3. List — `GET /webhook/framework/suggestions`
Validate session → return suggestions (reviewers see their own + statuses; you see all).

### 4. Decide — `POST /webhook/framework/decide`
Owner-only. Set status → if approved and type=edit, merge into the canonical `framework.json` → push to your static host (commit to the repo, or upload to the bucket/Netlify via API). Tip: stage approvals and publish in batches as versioned releases (v3.3, v3.4) instead of live-publishing every click — keeps the public page stable and gives you release notes to post on LinkedIn.

### Database (Supabase)
Full schema in `schema.sql` — run it once in the Supabase SQL Editor. Setup:
1. Create a project at supabase.com (free tier is plenty).
2. SQL Editor → paste `schema.sql` → Run. This creates `invitees` (the allowlist — you're seeded as owner), `sessions`, `suggestions`, `framework_versions`, plus `pending_queue` and `contributors` views, with RLS locked so only the service key can read/write.
3. Project Settings → API → copy the **service_role** key and URL into an n8n Postgres/Supabase credential. Never put this key in the browser — review.html only ever talks to n8n.
4. Each workflow's exact SQL is commented at the bottom of `schema.sql`, including the rate-limit check.

Manage invites by inserting rows into `invitees` (Supabase Table Editor works fine as the UI for this).

## Security checklist
- Gate = allowlist, not OAuth. LinkedIn only proves identity; the allowlist grants access.
- Sanitize all submitted text server-side too (the page already renders user text as plain text, never HTML).
- Rate-limit the submit webhook (n8n: simple count-per-session check) to stop spam.
- Webhook URLs are guessable — every endpoint must validate the session, not just the UI.
- Serve `review.html` from a separate path/subdomain that isn't linked from the public page.

## The "HOW" dimension (use cases, process guides)
Already modeled. Each cell carries:
```json
"how": { "processGuide": null, "useCases": [] }
```
When ready: the review panel gets a third tab ("Suggest a process guide"), the public page gets a click-to-expand view per cell, and the same suggest→approve pipeline handles it with zero backend changes — it's just two more fields in the diff. This is the payoff of moving content into structured data: new dimensions are fields, not pages.

## Suggested next steps
1. Verify/correct `framework.json` against your source (or send me the page source for exact extraction, tooltips included).
2. Refactor the public page to render from `framework.json` (small JS change; markup stays identical).
3. Stand up the 4 n8n workflows; flip `CONFIG.mockMode` to false.
4. Add a visible "Reviewed by" credits strip with LinkedIn profile links — it's the incentive for contributors and feeds traffic back from LinkedIn.
