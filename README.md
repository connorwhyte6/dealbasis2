# DealBasis: the simple deploy (no build step)

These files are the whole website, with no folders, no build and no packages. Vercel serves them as they are.

## 1. Supabase (skip if already done)

1. In your Supabase project, open **SQL Editor → New query**, paste all of `schema.sql` and click **Run**. Optional first: in that file, put your email on the `owner_email` line and remove the `-- ` in front, so only you can become the first admin.
2. **Authentication → URL Configuration:** set **Site URL** to your Vercel address (e.g. `https://dealbasis-site.vercel.app`), and add the same address followed by `/**` under **Redirect URLs**.

## 2. GitHub: a fresh repository

1. Create a **new** repository (e.g. `dealbasis-site`, Private). Use a new one so nothing from the earlier attempt (`build.js`, `package.json`, `src`) is left behind.
2. Click **uploading an existing file**, select **all the files** in this folder and drag them in. There are no folders this time. Click **Commit changes**.
3. Click **config.js**, then the **pencil icon** (Edit). Paste your two Supabase values between the quotes:
   - `supabaseUrl`: your Project URL, e.g. `https://abcdefghijklmnopqrst.supabase.co`
   - `supabaseAnonKey`: the **anon public** key (`eyJ…`) or **publishable** key (`sb_publishable_…`). Never the secret key.

   Then click **Commit changes**.

## 3. Vercel

1. **Add New… → Project**, then import the new repository.
2. Leave **Framework Preset** as **Other**. Leave the build and output settings empty, and add no environment variables. Click **Deploy**.
3. Open the address Vercel gives you, click **Create an account** and confirm your email. You're the admin.

The old Vercel project can be deleted: **its Settings → scroll down → Delete Project**.

## Updating later

Replace a file on GitHub (**Add file → Upload files**, then commit). Vercel republishes within a minute.

## Before real deal data goes in

The notes in the full README still apply:

- Connect an email sender in Supabase so teammates get confirmation emails. The built-in one only reaches your own Supabase team, at 2 per hour.
- Move Supabase to Pro for backups and so the project never pauses.
- Move Vercel to Pro for commercial use.

| File | What it is |
|---|---|
| `index.html` | Homepage: what DealBasis does, with Sign in and Try the sample deal. Sign-in links from emails that land here go straight on to `/signin` |
| `product.html`, `why.html`, `example.html`, `faq.html` | Website pages at `/product`, `/why`, `/example` and `/faq`: product tour and features, why deals die with sources, the Project Saguaro example, and FAQ with security |
| `home.css`, `home.js` | Shared styles and script for the homepage and the website pages |
| `signin.html` | Sign-in page (at `/signin`): sign in, create account, email sign-in link, password reset |
| `app.html` | The DealBasis platform (at `/app`; the sample is at `/app?demo=1`) |
| `admin.html` | Workspace admin: invites, access, firm domain (at `/admin`) |
| `adapter.js` | Connects the platform to Supabase |
| `config.js` | Your Supabase URL and public key, the only file you edit |
| `site.css`, `favicon.svg` | Styles and icon |
| `vercel.json` | Clean addresses and security headers |
| `schema.sql` | Run once in Supabase; not published with the site |
