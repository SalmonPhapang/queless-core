-- Push token isolation:
--   * identify which Queless app/audience owns each delivery instrument
--   * keep sign-out deletes scoped to the exact token/endpoint
--   * remove rows that are shared across users or clearly stale
--
-- Existing FCM rows were written by the Flutter store app; Expo rows and
-- browser subscriptions belong to the customer app. New clients always send
-- app_id explicitly, while the default keeps any un-updated Flutter writer
-- working as the store app.

alter table public.user_fcm_tokens
  add column if not exists app_id text not null default 'store';

alter table public.user_fcm_tokens
  drop constraint if exists user_fcm_tokens_app_id_check;
alter table public.user_fcm_tokens
  add constraint user_fcm_tokens_app_id_check
  check (app_id in ('customer', 'merchant', 'store', 'driver'));

comment on column public.user_fcm_tokens.app_id is
  'Queless app/audience that registered the token: customer, merchant, store or driver.';

update public.user_fcm_tokens
   set app_id = case when provider = 'expo' then 'customer' else 'store' end
 where app_id <> case when provider = 'expo' then 'customer' else 'store' end;

create index if not exists user_fcm_tokens_app_scope_idx
  on public.user_fcm_tokens (user_id, app_id, provider);

alter table public.web_push_subscriptions
  add column if not exists app_id text not null default 'customer';

alter table public.web_push_subscriptions
  drop constraint if exists web_push_subscriptions_app_id_check;
alter table public.web_push_subscriptions
  add constraint web_push_subscriptions_app_id_check
  check (app_id in ('customer', 'merchant'));

comment on column public.web_push_subscriptions.app_id is
  'Queless app that owns the browser subscription. The PWA uses customer.';

update public.web_push_subscriptions
   set app_id = 'customer'
 where app_id <> 'customer';

create index if not exists web_push_subscriptions_app_scope_idx
  on public.web_push_subscriptions (user_id, app_id);

-- A registration token identifies one app installation. When the same token is
-- attached to two users the delivery target is ambiguous, so drop every row
-- involved and let each app re-register on next launch.
delete from public.user_fcm_tokens t
 where exists (
   select 1
     from public.user_fcm_tokens s
    where s.token = t.token
      and s.user_id <> t.user_id
 );

-- Six months without a refresh means the installation is no longer a reliable
-- delivery target. Recent-but-quiet devices are deliberately kept so infrequent
-- store owners do not silently lose notifications.
delete from public.user_fcm_tokens
 where updated_at < timezone('utc', now()) - interval '180 days';

delete from public.web_push_subscriptions
 where updated_at < timezone('utc', now()) - interval '180 days';
