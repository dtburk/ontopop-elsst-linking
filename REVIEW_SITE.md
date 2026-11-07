# Collaborative review site (Phase 5)

The human-review interface is a static web app in `docs/`, hosted on
**GitHub Pages**. Reviewer profiles and votes are stored in a free
**Google Firebase Firestore** database. GitHub Pages can only serve files, so
the page reads and writes votes directly in Firestore. No server is needed.

```
docs/index.html, app.js   the app
docs/review.json          term/candidate data  ← scripts/07_build_review.R
docs/config.json          Firebase project settings (you fill these in)
firestore.rules           database security rules (paste into Firebase)
scripts/08_fetch_votes.R  download votes → data/review_votes.csv, data/review_summary.csv
```

Until `docs/config.json` is filled in, the site runs in **local demo mode**.
Everything works, but votes are stored only in the current browser. You can
force demo mode at any time by adding `?local` to the URL, for example to try
things out without touching the shared data.

## One-time setup

### 1. Firebase (about 10 minutes, free "Spark" plan, no credit card)

1. Go to <https://console.firebase.google.com>, click **Create a project**, and
   name it (e.g. `ontopop-elsst-review`). Google Analytics is not needed.
2. **Build → Firestore Database → Create database**. Choose a location
   (e.g. `nam5 (us-central)`), then start in **production mode**.
3. In Firestore, open the **Rules** tab, replace its contents with
   `firestore.rules` from this repo, and click **Publish**.
4. **Project settings (gear icon) → General → Your apps → Web (`</>`)**.
   Register an app (no Hosting needed). Copy `apiKey`, `projectId` and `appId`
   from the config it shows into `docs/config.json`:

   ```json
   { "firebase": { "apiKey": "AIza…", "projectId": "ontopop-elsst-review", "appId": "1:…:web:…" } }
   ```

   These values are identifiers, not secrets. Firebase web configs are meant to
   be public, and access is governed by the security rules.

### 2. GitHub Pages

1. Create a GitHub repository and push this project to it. Pages from a private
   repo need a paid or education plan, and **the published site is public
   either way**. `docs/review.json` contains OntoPop labels, glosses and
   definitions, so check you are comfortable publishing those.
2. Repository **Settings → Pages → Build and deployment**: Source *Deploy from
   a branch*, branch `main` (or whichever you use), folder **`/docs`**.
3. After a minute the site is at `https://<user>.github.io/<repo>/`.
   Send that URL to reviewers.

## Day-to-day

- **After changing `firestore.rules`** (it gained reviewer-added links on
  2026-11-06), paste it into the Firebase console again and click
  **Publish**. Until then, adding links fails with "permission-denied", though
  ordinary votes still work.
- **Rebuild the data** after re-running earlier phases:
  `Rscript scripts/07_build_review.R`, then commit and push `docs/review.json`.
  Votes are keyed by OntoPop code + ELSST UUID, so they stay attached to their
  links across rebuilds. Votes on links that disappear are kept in the
  database, and `08_fetch_votes.R` warns about them.
- **Download the votes**: `Rscript scripts/08_fetch_votes.R`.
  - `data/review_votes.csv` has one row per human vote: reviewer, affiliation,
    match type, note, and timestamps.
  - `data/review_summary.csv` has one row per link, with the gpt-4o
    assignment and the count of human votes for each type. It includes
    reviewer-added links (`link_source`), with who added them.
- **Preview locally**: the page loads `review.json` with `fetch`, so it must be
  served over HTTP rather than opened from disk:
  `cd docs && python -m http.server 8000`, then open
  <http://localhost:8000/?local>.

## How the app works

- **Reviewers** pick their profile, or create one with a name and
  affiliation. The choice is remembered per browser, and anyone can switch
  profiles from the button at the top right. There are no passwords.
- **Votes.** Each candidate link shows a list of votes. gpt-4o's assignment
  appears as the first vote, with its rationale as the note. Every reviewer
  can add one vote per link (match type plus an optional comment), and can
  edit or delete their own vote. A badge on each card reads *unreviewed*,
  *1 reviewer*, *2 reviewers*, and so on.
- **Adding links gpt-4o missed.** Two buttons propose a new link:
  - *✚ Add a link to an ELSST concept*, on each OntoPop class, searches all
    3,470 ELSST concepts by label, alternative label and definition.
  - *✚ Link this ELSST concept to another OntoPop class*, on each ELSST card,
    searches OntoPop classes.

  The proposer chooses the relation and can add a comment. The dialog spells
  out the relation in words (e.g. "ELSST X is narrower than OntoPop Y") to
  catch direction mistakes, and it refuses pairs that already exist, pointing
  to them instead. The new link appears under *Links added by reviewers* on
  the OntoPop class's page, with the proposer's vote, and others vote on it as
  usual. The proposer can remove it while nobody else has voted on it.
- **Human review log** (header button, or `…/#log`): a table of every human
  vote, showing:
  - the OntoPop class
  - gpt-4o's relation (hover to see its rationale)
  - the ELSST concept
  - the reviewer and institution
  - the vote and note
  - the date

  Every column can be filtered. "Reviewer vote" also offers *same as gpt-4o*
  and *differs from gpt-4o*. Click a heading to sort, and click a class to
  jump to that link.
- **Progress** counts links with at least one human vote, out of all 19,022
  gpt-4o assignments. Reviewer-added links are counted separately. The smaller figure next to it counts only the 9,404
  links where gpt-4o proposed a match.
- **View options:**
  - *Hide human-reviewed links* hides any link with a human vote.
  - *Hide human-rejected links* hides links whose human votes are **all**
    "reject". A link with a reject vote and a match vote stays visible.
  - Links you vote on stay visible until you move to another term.
- **Sidebar.** The OntoPop hierarchy starts collapsed to the two root classes.
  Click ▸ to expand or collapse a class, and click a label to open it. Because
  OntoPop is a DAG, a class with several parents appears under each of them.
  The dot next to each term shows its review status. The category filter
  narrows the tree to matching terms and dims their non-matching ancestors.
- **URLs** include the term code (e.g. `…/#101-1`), so reviewers can share
  links to specific terms.

## Limits and hardening

- **Free-tier quota.** Firestore's free tier allows 50k reads and 20k writes
  per day. Votes are stored in one document per OntoPop section (about 210
  documents), so opening the page costs at most about 210 reads, however many
  votes exist. Each vote, edit or delete is one write.
- **Identity is not verified.** Anyone with the URL can read the data and vote
  under any profile. Use the site only with a trusted group. If that becomes a
  problem, Firebase Authentication (e.g. Google sign-in) plus rules that tie
  each vote to `request.auth.uid` would enforce ownership, at the cost of
  requiring reviewers to sign in.
- **Backups.** Run `scripts/08_fetch_votes.R` periodically. The CSVs it writes
  are a complete snapshot of the votes.

### Alternatives considered

- **Supabase** (Postgres) also has a free tier, but it pauses projects after a
  week of inactivity.
- **Google Sheets + Apps Script** would put votes straight into a spreadsheet,
  but it is slower and has no live updates. University Google Workspace
  domains also often block anonymous access to web apps, which would lock out
  reviewers from other institutions.
- **Cloudflare Workers + D1** is free and capable, but means writing and
  deploying a small API.
