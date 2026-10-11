# DealBasis: SOC 2 readiness

SOC 2 is a report written by an independent CPA firm after auditing how a company protects customer data. Code alone can't make a product "SOC 2 compliant". The auditor tests the company's controls: its policies, the people running it, the vendors it relies on and the product itself.

- **Type I** checks that the controls are designed properly, on a single date.
- **Type II** checks that they actually operated over a period, usually 3 to 12 months. Buyers in private equity usually ask for this one.

This file lists what the platform already does, what to set up in Supabase and Vercel, and what the company still has to put in place.

## 1. Built into the platform

Each control is mapped to the SOC 2 Trust Services Criteria (CC = Common Criteria, the Security category every SOC 2 audit covers).

| Control | How DealBasis does it | Criteria |
|---|---|---|
| Each firm's data is isolated | Every deal, file, invite, member and log entry belongs to one workspace. The database enforces this with row-level security on every table and on file storage, so it doesn't depend on the app. Workspaces can't read or change each other's data. | CC6.1, CC6.3 |
| Least privilege | Three roles: Admin (access and settings), Member (works on deals), Viewer (read only). Viewers can't write or upload, also enforced in the database. | CC6.1, CC6.3 |
| Joining is controlled | People join a firm by an admin's invite or by a confirmed email at the firm's domain. Personal domains (gmail.com and similar) can't be used as a firm domain, and each domain belongs to one workspace. Anyone else gets a separate, empty workspace of their own. | CC6.2 |
| Removing access | An admin can remove someone, which takes effect immediately. Removed people can't rejoin through the firm's domain until an admin restores or re-invites them. | CC6.2, CC6.3 |
| Two-factor sign-in | Anyone can turn on authenticator-app codes (TOTP) on the Account security page. An admin can require them for the whole workspace. Once required, sessions without two-factor get no data at all, enforced by the database. An admin can't require it before using it themselves, so nobody gets locked out. | CC6.1 |
| Sign-out after inactivity | Each workspace sets an inactivity limit, from 15 minutes to 8 hours (30 minutes by default). It applies across all open tabs. | CC6.1 |
| Audit log | The database itself records sign-ins and sign-outs, deal changes, uploads, deletions, file openings, invites, access changes, settings changes, exports and two-factor changes, with who and when. Nobody can edit or delete entries from the app, only admins can read them, and they're kept even after a workspace is deleted. Admins can filter the log and download it as CSV. | CC7.2, CC7.3, CC4.1 |
| Data export | An admin can download the whole workspace (deals, settings, members, activity log and every file) as one ZIP file. | Confidentiality, CC6.5 |
| Data deletion | An admin can permanently delete the workspace, which removes all its files, deals, invites and members. The deletion itself is recorded in the audit log. | C1.2, CC6.5 |
| Encryption | Every connection uses HTTPS: Vercel serves the site and Supabase the data, with HSTS turned on. Supabase encrypts the database and files on disk. | CC6.1, CC6.7 |
| Security headers | HSTS, no framing (to block clickjacking), no MIME sniffing, a strict referrer policy, and camera, microphone and location turned off. | CC6.6 |
| Private file storage | Files sit in a private bucket and are reached through the signed-in person's access, or through 5-minute signed links. There are no public links. | CC6.1 |
| Deterministic processing | Findings come from fixed, tested rules. No AI model reads customer documents, and every figure links back to its source. | PI1.2, PI1.4 |

## 2. One-time setup in Supabase and Vercel

1. **Run the new `schema.sql`.** In Supabase, open SQL Editor, then New query, paste the whole file and click Run. This moves existing deals, members and files into one workspace. It's safe to run more than once.
2. **Authentication settings** (Supabase, under Authentication):
   - MFA: make sure **TOTP** is enabled. It is by default.
   - Set a minimum password length of at least 8 characters, and turn on **leaked password protection**, which checks passwords against known breaches. It's a Pro plan feature.
   - Under Sessions, set a **time-box** (for example, 12 hours) so sessions end even while someone is active. This is a Pro plan feature.
   - Connect your own email sender (SMTP) so confirmation and reset emails reach people reliably.
3. **Move Supabase to the Pro plan.** It adds daily backups and stops the project from pausing. Add point-in-time recovery if you need finer restores. Backups and tested restores are an availability control (A1.2).
4. **Turn on two-factor sign-in for the Supabase, Vercel and GitHub accounts themselves,** and limit who can open them. Whoever owns these accounts can see all customer data. That's normal, but the auditor will check that access is limited, reviewed and logged.
5. **Keep the Supabase secret (service role) key out of the code.** Only the public key belongs in `config.js`.

## 3. What the company still needs

The auditor will ask for these, and the platform can't supply them:

- **A legal entity.** The audit is of a company, so DealBasis needs to be incorporated first.
- **Written policies,** approved and reviewed every year:
  - information security
  - access control
  - change management (code review before deploying)
  - incident response
  - business continuity and disaster recovery
  - data classification, retention and deletion
  - vendor management
  - acceptable use
  - risk assessment
- **People controls:** background checks, security awareness training, signed confidentiality agreements, and onboarding and offboarding checklists.
- **Vendor reviews:** collect the SOC 2 reports of Supabase, Vercel and GitHub (each has one, usually shared under NDA or on paid plans) and review them every year.
- **Regular evidence:** quarterly access reviews (the Members list and the audit log export help here), an annual risk assessment, an annual penetration test, and tracking of security issues to resolution.
- **A compliance platform and an auditor.** Tools like Vanta, Drata or Secureframe connect to GitHub, Supabase and Vercel, supply policy templates and collect evidence automatically. They also introduce audit firms. The usual path is to get ready, take a Type I, then run a Type II window.

## 4. Limits to be open about

- Whoever owns the Supabase project can read stored data from the Supabase dashboard. This is true of almost every hosted product. It's handled by limiting and reviewing who holds those accounts, not by the app.
- The audit log records what happens through DealBasis. Changes made directly in the Supabase dashboard show up in Supabase's own logs, not in the DealBasis log.
- Until the company has completed an audit, don't describe DealBasis as "SOC 2 compliant" or "SOC 2 certified". It's accurate to say it's "built with SOC 2 controls" or "preparing for SOC 2".
