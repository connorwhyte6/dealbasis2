-- DealBasis billing: commands you run yourself in Supabase (SQL Editor -> New query).
-- Do NOT run this whole file at once. Copy the one block you need, fill in the email or numbers, and Run.
--
-- Pricing (per editor seat, per year; Viewers are free and unlimited; every plan has every feature):
--   1-2 editors   $1,500 per seat
--   3-9 editors   $1,275 per seat (15% off)
--   10+ editors   $1,125 per seat (25% off)
-- Examples: 1 = $1,500 · 2 = $3,000 · 3 = $3,825 · 5 = $6,375 · 10 = $11,250 · 12 = $13,500
--
-- Seat requests from customers arrive in the support_requests table with kind = 'billing'
-- (Table Editor -> support_requests). The admin page sends the seats asked for and the yearly price.

-- 1. Find a customer's workspace by any of its people's email ----------------------------------------
select w.id, w.name, w.plan_status, w.seats, public.seats_used(w.id) as seats_used,
       w.trial_ends_at, w.paid_until, m.email, m.role
from public.workspaces w join public.members m on m.workspace_id = w.id
where lower(m.email) = lower('customer@firm.com');

-- 2. Your own workspace: complimentary, never expires ----------------------------------
update public.workspaces set plan_status = 'comp', seats = 10
where id = (select workspace_id from public.members where lower(email) = lower('connorwhyte6@gmail.com'));

-- 3. Customer paid: start a 12-month subscription ------------------------------------------------------
update public.workspaces
set plan_status = 'active', seats = 3, paid_until = now() + interval '1 year', billing_email = 'ap@firm.com'
where id = 'WORKSPACE-ID-FROM-STEP-1';

-- 4. Renewal paid: add another year to the current end date --------------------------------------------
update public.workspaces set plan_status = 'active', paid_until = greatest(coalesce(paid_until, now()), now()) + interval '1 year'
where id = 'WORKSPACE-ID-FROM-STEP-1';

-- 5. Customer bought more seats mid-year (invoice the prorated amount, then) ----------------------------
update public.workspaces set seats = 5 where id = 'WORKSPACE-ID-FROM-STEP-1';

-- 6. Design partner pilot paid ($750): like a subscription, but for 60 days, on the seats they asked for
update public.workspaces set plan_status = 'pilot', seats = 5, paid_until = now() + interval '60 days', billing_email = 'ap@firm.com'
where id = 'WORKSPACE-ID-FROM-STEP-1';
-- The pilot is the start of their design-partner subscription. When it ends, invoice the first year
-- ($750 per editor seat, minus the $750 pilot fee); once paid, use block 3 to start the year. If they told you
-- before the end that they aren't continuing, do nothing: the workspace goes read-only when the pilot ends.

-- 6b. A free trial longer than 14 days or above the 50 seats admins can set themselves -------------------------------------------------------
update public.workspaces set plan_status = 'trial', seats = 8, trial_ends_at = now() + interval '60 days', trial_extended = true
where id = 'WORKSPACE-ID-FROM-STEP-1';

-- 7. Extend a trial by hand (beyond the one 7-day extension admins can take themselves) -----------------
update public.workspaces set trial_ends_at = greatest(trial_ends_at, now()) + interval '14 days'
where id = 'WORKSPACE-ID-FROM-STEP-1';

-- 8. Canceled: the workspace becomes read-only right away (people can still open and export) -----------
update public.workspaces set plan_status = 'canceled' where id = 'WORKSPACE-ID-FROM-STEP-1';

-- 9. Expired or canceled for more than 30 days: list them, so you can delete their data as the contracts say
select w.id, w.name, w.plan_status, w.trial_ends_at, w.paid_until
from public.workspaces w
where (w.plan_status = 'trial' and w.trial_ends_at < now() - interval '30 days')
   or (w.plan_status = 'active' and w.paid_until < now() - interval '44 days')
   or (w.plan_status = 'canceled');

-- 10. Seat requests waiting for you --------------------------------------------------------------------
select r.created_at, w.name, r.email, r.subject, r.message
from public.support_requests r join public.workspaces w on w.id = r.workspace_id
where r.kind = 'billing' and r.status = 'open' order by r.created_at desc;
