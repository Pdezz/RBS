-- =====================================================================
-- Collaborative review DB for rightbrained.cloud
-- Run once in Supabase: SQL Editor -> New query -> paste -> Run
-- =====================================================================

-- 1. Who may sign in (the actual access gate — LinkedIn only proves identity)
create table invitees (
  email        text primary key,            -- must match the email LinkedIn returns
  name         text,
  linkedin_url text,
  role         text not null default 'reviewer' check (role in ('owner','reviewer')),
  status       text not null default 'invited' check (status in ('invited','active','revoked')),
  invited_by   text,
  created_at   timestamptz not null default now()
);

-- 2. Active sessions (issued by n8n after OAuth + allowlist check)
create table sessions (
  token      uuid primary key default gen_random_uuid(),
  email      text not null references invitees(email) on delete cascade,
  name       text,
  picture    text,                          -- LinkedIn avatar URL, for attribution
  expires_at timestamptz not null default now() + interval '14 days',
  created_at timestamptz not null default now()
);
create index sessions_email_idx on sessions(email);

-- 3. Suggestions (the core table)
create table suggestions (
  id               uuid primary key default gen_random_uuid(),
  cell_id          text not null,           -- framework.json cell id, e.g. 'item-writing'
  type             text not null check (type in ('edit','comment')),
  -- snapshot of the cell at submit time, so diffs stay readable after later edits
  prev_label       text,
  prev_tooltip     text,
  -- the proposal (null = unchanged)
  proposed_label   text,
  proposed_tooltip text,
  comment          text,                    -- reason for edit, or the comment itself
  author_email     text not null references invitees(email),
  author_name      text,
  status           text not null default 'pending'
                   check (status in ('pending','approved','rejected','addressed')),
  decided_by       text,
  decision_note    text,
  decided_at       timestamptz,
  created_at       timestamptz not null default now()
);
create index suggestions_status_idx  on suggestions(status);
create index suggestions_cell_idx    on suggestions(cell_id);
create index suggestions_author_idx  on suggestions(author_email);

-- 4. Published releases (batch approvals into versions: v3.3, v3.4, ...)
create table framework_versions (
  version      text primary key,            -- 'v3.3'
  data         jsonb not null,              -- full framework.json at publish time
  notes        text,                        -- release notes (good LinkedIn post material)
  published_by text,
  published_at timestamptz not null default now()
);

-- 5. Convenience view for the approval queue / notification email
create view pending_queue as
  select s.id, s.cell_id, s.type,
         s.prev_label, s.proposed_label,
         s.prev_tooltip, s.proposed_tooltip,
         s.comment, s.author_name, s.author_email, s.created_at
  from suggestions s
  where s.status = 'pending'
  order by s.created_at;

-- 6. Contributor credits ("Reviewed by" strip on the public page)
create view contributors as
  select author_name, author_email, count(*) as approved_count,
         max(decided_at) as last_contribution
  from suggestions
  where status = 'approved'
  group by author_name, author_email
  order by approved_count desc;

-- =====================================================================
-- Security: lock everything down; only n8n (service_role key) gets in.
-- The browser never talks to Supabase directly — always through n8n.
-- =====================================================================
alter table invitees           enable row level security;
alter table sessions           enable row level security;
alter table suggestions        enable row level security;
alter table framework_versions enable row level security;
-- No policies created on purpose: anon/authenticated keys are denied
-- everything; the service_role key (used by n8n) bypasses RLS.

-- =====================================================================
-- Seed: you
-- =====================================================================
insert into invitees (email, name, linkedin_url, role, status, invited_by)
values ('paul.dezzutto@gmail.com', 'Paul Dezzutto',
        'https://www.linkedin.com/in/pauldezzutto/', 'owner', 'active', 'self');

-- =====================================================================
-- Queries n8n will run (reference)
-- =====================================================================
-- Gate check (auth workflow):
--   select * from invitees where email = $1 and status = 'active';
-- Create session:
--   insert into sessions (email, name, picture) values ($1,$2,$3) returning token;
-- Validate session (every webhook):
--   select i.email, i.role, s.name from sessions s
--     join invitees i on i.email = s.email
--   where s.token = $1 and s.expires_at > now() and i.status = 'active';
-- Submit:
--   insert into suggestions (cell_id, type, prev_label, prev_tooltip,
--     proposed_label, proposed_tooltip, comment, author_email, author_name)
--   values (...) returning id;
-- Rate limit (before insert):
--   select count(*) from suggestions
--   where author_email = $1 and created_at > now() - interval '1 hour';  -- cap at ~20
-- Decide:
--   update suggestions set status=$2, decided_by=$3, decided_at=now(),
--     decision_note=$4 where id=$1 and status='pending' returning *;
-- Publish release:
--   insert into framework_versions (version, data, notes, published_by)
--   values ($1, $2::jsonb, $3, $4);
