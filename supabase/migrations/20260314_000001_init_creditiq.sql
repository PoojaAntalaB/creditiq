create extension if not exists pgcrypto;

create or replace function public.update_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text not null unique,
  avatar_url text,
  role text not null default 'analyst' check (role in ('admin', 'analyst', 'underwriter')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1), 'User'),
    new.email
  );

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

create trigger profiles_updated_at
  before update on public.profiles
  for each row execute procedure public.update_updated_at();

create table public.applications (
  id uuid primary key default gen_random_uuid(),
  application_id text not null unique,
  applicant_name text not null,
  applicant_email text not null,
  phone text,
  date_of_birth date,
  gender text check (gender in ('male', 'female', 'other')),
  address text,
  city text,
  state text,
  pincode text,
  loan_amount numeric(12,2) not null check (loan_amount >= 10000 and loan_amount <= 50000000),
  loan_purpose text not null check (loan_purpose in ('home', 'auto', 'personal', 'business')),
  employment_type text check (employment_type in ('salaried', 'self_employed', 'unemployed', 'retired')),
  annual_income numeric(12,2),
  credit_score integer check (credit_score is null or (credit_score >= 300 and credit_score <= 900)),
  existing_loans integer not null default 0 check (existing_loans >= 0),
  monthly_emi numeric(10,2) not null default 0 check (monthly_emi >= 0),
  data_sources text[] not null default '{}'::text[],
  status text not null default 'pending' check (status in ('pending', 'approved', 'denied', 'review', 'expired')),
  notes text,
  submitted_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger applications_updated_at
  before update on public.applications
  for each row execute procedure public.update_updated_at();

create table public.credit_scores (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(id) on delete cascade,
  ai_score numeric(5,2) not null check (ai_score >= 300 and ai_score <= 900),
  risk_level text not null check (risk_level in ('very_low', 'low', 'medium', 'high', 'very_high')),
  approval_prob numeric(5,4) check (approval_prob is null or (approval_prob >= 0 and approval_prob <= 1)),
  score_factors jsonb,
  model_version text not null default 'v1.0',
  decision text check (decision in ('approve', 'deny', 'review')),
  decision_reason text,
  calculated_at timestamptz not null default now()
);

create table public.risk_models (
  id uuid primary key default gen_random_uuid(),
  model_name text not null,
  version text not null,
  description text,
  accuracy_auc numeric(4,3),
  precision_score numeric(4,3),
  recall_score numeric(4,3),
  is_active boolean not null default false,
  deployed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (model_name, version)
);

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null check (entity_type in ('application', 'credit_score', 'model')),
  entity_id uuid not null,
  action text not null,
  performed_by text not null,
  details jsonb,
  ip_address text,
  created_at timestamptz not null default now()
);

create index applications_created_at_idx on public.applications (created_at desc);
create index applications_status_idx on public.applications (status);
create index applications_loan_purpose_idx on public.applications (loan_purpose);
create index applications_submitted_by_idx on public.applications (submitted_by);
create index applications_applicant_email_idx on public.applications (lower(applicant_email));
create index applications_search_idx on public.applications using gin (
  to_tsvector('simple', coalesce(application_id, '') || ' ' || coalesce(applicant_name, '') || ' ' || coalesce(applicant_email, ''))
);

create index credit_scores_application_id_idx on public.credit_scores (application_id, calculated_at desc);
create index credit_scores_risk_level_idx on public.credit_scores (risk_level);
create unique index risk_models_single_active_idx on public.risk_models (is_active) where is_active;
create index audit_logs_entity_idx on public.audit_logs (entity_type, entity_id, created_at desc);

alter table public.profiles enable row level security;
alter table public.applications enable row level security;
alter table public.credit_scores enable row level security;
alter table public.risk_models enable row level security;
alter table public.audit_logs enable row level security;

create policy "Users can view own profile"
  on public.profiles
  for select
  using (auth.uid() = id);

create policy "Users can insert own profile"
  on public.profiles
  for insert
  with check (auth.uid() = id);

create policy "Users can update own profile"
  on public.profiles
  for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

create policy "Authenticated users can view applications"
  on public.applications
  for select
  using (auth.role() = 'authenticated');

create policy "Authenticated users can insert applications"
  on public.applications
  for insert
  with check (auth.role() = 'authenticated' and (submitted_by is null or submitted_by = auth.uid()));

create policy "Authenticated users can update applications"
  on public.applications
  for update
  using (auth.role() = 'authenticated')
  with check (auth.role() = 'authenticated');

create policy "Authenticated users can delete applications"
  on public.applications
  for delete
  using (auth.role() = 'authenticated');

create policy "Authenticated users can view credit scores"
  on public.credit_scores
  for select
  using (auth.role() = 'authenticated');

create policy "Authenticated users can insert credit scores"
  on public.credit_scores
  for insert
  with check (auth.role() = 'authenticated');

create policy "Authenticated users can update credit scores"
  on public.credit_scores
  for update
  using (auth.role() = 'authenticated')
  with check (auth.role() = 'authenticated');

create policy "Authenticated users can view risk models"
  on public.risk_models
  for select
  using (auth.role() = 'authenticated');

create policy "Authenticated users can view audit logs"
  on public.audit_logs
  for select
  using (auth.role() = 'authenticated');

create policy "Authenticated users can insert audit logs"
  on public.audit_logs
  for insert
  with check (auth.role() = 'authenticated');

insert into public.risk_models (
  model_name,
  version,
  description,
  accuracy_auc,
  precision_score,
  recall_score,
  is_active,
  deployed_at
) values (
  'CreditIQ Risk Predictor',
  'v1.0',
  'Baseline credit risk model trained on bureau, income, debt ratio, and repayment behaviour signals.',
  0.870,
  0.830,
  0.790,
  true,
  now()
);

insert into public.applications (
  application_id,
  applicant_name,
  applicant_email,
  phone,
  date_of_birth,
  gender,
  city,
  state,
  loan_amount,
  loan_purpose,
  employment_type,
  annual_income,
  credit_score,
  existing_loans,
  monthly_emi,
  data_sources,
  status
) values
  ('APP-001', 'Aarav Shah', 'aarav.shah@email.com', '9876543201', '1990-03-15', 'male', 'Ahmedabad', 'Gujarat', 500000, 'home', 'salaried', 800000, 720, 1, 12000, array['bureau','bank'], 'approved'),
  ('APP-002', 'Diya Patel', 'diya.patel@email.com', '9876543203', '1992-07-22', 'female', 'Ahmedabad', 'Gujarat', 300000, 'personal', 'salaried', 600000, 680, 0, 5000, array['bureau','bank','utility'], 'approved'),
  ('APP-003', 'Rohan Mehta', 'rohan.mehta@email.com', '9876543205', '1988-11-10', 'male', 'Surat', 'Gujarat', 1500000, 'business', 'self_employed', 1200000, 610, 2, 25000, array['bureau','bank'], 'review'),
  ('APP-004', 'Priya Joshi', 'priya.joshi@email.com', '9876543207', '1995-05-18', 'female', 'Vadodara', 'Gujarat', 200000, 'auto', 'salaried', 480000, 700, 1, 8000, array['bureau'], 'approved'),
  ('APP-005', 'Arjun Singh', 'arjun.singh@email.com', '9876543209', '1985-09-03', 'male', 'Rajkot', 'Gujarat', 2500000, 'home', 'salaried', 1800000, 580, 3, 45000, array['bureau','bank'], 'denied'),
  ('APP-006', 'Kavya Nair', 'kavya.nair@email.com', '9876543211', '1993-01-25', 'female', 'Ahmedabad', 'Gujarat', 100000, 'personal', 'salaried', 360000, 650, 0, 3000, array['bureau','utility'], 'pending'),
  ('APP-007', 'Vivaan Gupta', 'vivaan.gupta@email.com', '9876543213', '1991-12-08', 'male', 'Surat', 'Gujarat', 750000, 'business', 'self_employed', 960000, 630, 1, 15000, array['bureau','bank'], 'review'),
  ('APP-008', 'Ananya Sharma', 'ananya.sharma@email.com', '9876543215', '1987-04-14', 'female', 'Ahmedabad', 'Gujarat', 400000, 'auto', 'salaried', 720000, 760, 0, 6000, array['bureau','bank','utility'], 'approved'),
  ('APP-009', 'Ishaan Verma', 'ishaan.verma@email.com', '9876543217', '1997-08-30', 'male', 'Gandhinagar', 'Gujarat', 150000, 'personal', 'unemployed', 120000, 520, 2, 5000, array['bureau'], 'denied'),
  ('APP-010', 'Riya Desai', 'riya.desai@email.com', '9876543219', '1994-02-19', 'female', 'Vadodara', 'Gujarat', 400000, 'home', 'salaried', 540000, 670, 1, 10000, array['bureau','bank'], 'pending');

insert into public.credit_scores (
  application_id,
  ai_score,
  risk_level,
  approval_prob,
  score_factors,
  model_version,
  decision,
  decision_reason
)
select
  a.id,
  case a.application_id
    when 'APP-001' then 820
    when 'APP-002' then 740
    when 'APP-003' then 620
    when 'APP-004' then 710
    when 'APP-005' then 560
    when 'APP-007' then 640
    when 'APP-008' then 790
    when 'APP-009' then 480
  end,
  case a.application_id
    when 'APP-001' then 'very_low'
    when 'APP-002' then 'low'
    when 'APP-003' then 'medium'
    when 'APP-004' then 'low'
    when 'APP-005' then 'high'
    when 'APP-007' then 'medium'
    when 'APP-008' then 'very_low'
    when 'APP-009' then 'very_high'
  end,
  case a.application_id
    when 'APP-001' then 0.9200
    when 'APP-002' then 0.8100
    when 'APP-003' then 0.5500
    when 'APP-004' then 0.7800
    when 'APP-005' then 0.2800
    when 'APP-007' then 0.6200
    when 'APP-008' then 0.8900
    when 'APP-009' then 0.1500
  end,
  case a.application_id
    when 'APP-001' then '{"income_stability": 90, "debt_to_income": -5, "bureau_score": 85, "employment_tenure": 70}'::jsonb
    when 'APP-002' then '{"income_stability": 82, "debt_to_income": -8, "bureau_score": 72, "employment_tenure": 64}'::jsonb
    when 'APP-003' then '{"income_stability": 61, "debt_to_income": -24, "bureau_score": 58, "cash_flow_consistency": 55}'::jsonb
    when 'APP-004' then '{"income_stability": 78, "debt_to_income": -10, "bureau_score": 70, "employment_tenure": 68}'::jsonb
    when 'APP-005' then '{"income_stability": 55, "debt_to_income": -40, "bureau_score": 44, "existing_exposure": -33}'::jsonb
    when 'APP-007' then '{"income_stability": 66, "debt_to_income": -18, "bureau_score": 61, "cash_flow_consistency": 60}'::jsonb
    when 'APP-008' then '{"income_stability": 88, "debt_to_income": -6, "bureau_score": 81, "employment_tenure": 74}'::jsonb
    when 'APP-009' then '{"income_stability": 32, "debt_to_income": -45, "bureau_score": 38, "existing_exposure": -28}'::jsonb
  end,
  'v1.0',
  case a.application_id
    when 'APP-001' then 'approve'
    when 'APP-002' then 'approve'
    when 'APP-003' then 'review'
    when 'APP-004' then 'approve'
    when 'APP-005' then 'deny'
    when 'APP-007' then 'review'
    when 'APP-008' then 'approve'
    when 'APP-009' then 'deny'
  end,
  case a.application_id
    when 'APP-005' then 'High debt-to-income ratio exceeds policy threshold of 45%.'
    when 'APP-009' then 'Insufficient income and high existing debt burden relative to requested loan.'
    else null
  end
from public.applications a
where a.application_id in ('APP-001', 'APP-002', 'APP-003', 'APP-004', 'APP-005', 'APP-007', 'APP-008', 'APP-009');

insert into public.audit_logs (
  entity_type,
  entity_id,
  action,
  performed_by,
  details
)
select
  'application',
  a.id,
  'submitted',
  'system',
  jsonb_build_object('application_id', a.application_id, 'status', a.status)
from public.applications a
union all
select
  'credit_score',
  cs.id,
  coalesce(cs.decision, 'review'),
  'system',
  jsonb_build_object(
    'application_id', a.application_id,
    'ai_score', cs.ai_score,
    'risk_level', cs.risk_level,
    'approval_prob', cs.approval_prob
  )
from public.credit_scores cs
join public.applications a on a.id = cs.application_id;
