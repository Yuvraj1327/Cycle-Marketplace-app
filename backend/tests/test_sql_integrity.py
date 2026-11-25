"""Runs the Step 5 PL/pgSQL functions against a REAL throwaway PostgreSQL cluster (initdb in a temp dir; Supabase's `auth`,
`storage` and roles are stubbed). Covers checkout, idempotency, stock, webhooks, cancellation, refunds, settlements, RLS and
genuine multi-session concurrency. Skipped automatically when PostgreSQL tools are not installed."""
import os
import shutil
import subprocess
import tempfile
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = sorted((ROOT / "supabase" / "migrations").glob("*.sql"))
SEED = ROOT / "supabase" / "seed" / "001_reference_categories.sql"
SQL_DIR = Path(__file__).parent / "sql"


def _find(tool: str) -> str | None:
    found = shutil.which(tool)
    if found:
        return found
    for base in ("/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/opt/postgresql@16/bin", "/usr/lib/postgresql/16/bin", "/usr/lib/postgresql/15/bin"):
        if (Path(base) / tool).exists():
            return str(Path(base) / tool)
    return None


TOOLS = {t: _find(t) for t in ("initdb", "pg_ctl", "psql")}
pytestmark = pytest.mark.skipif(not all(TOOLS.values()), reason="PostgreSQL tools (initdb/pg_ctl/psql) not installed")


class Cluster:
    def __init__(self):
        self.dir = Path(tempfile.mkdtemp(prefix="cmpg", dir="/tmp"))
        self.sock = self.dir / "s"
        self.sock.mkdir()
        self.port = str(54000 + os.getpid() % 900)

    def start(self):
        subprocess.run([TOOLS["initdb"], "-D", str(self.dir / "data"), "-U", "postgres", "--auth=trust"], check=True, capture_output=True)
        subprocess.run([TOOLS["pg_ctl"], "-D", str(self.dir / "data"), "-o", f"-p {self.port} -k {self.sock} -c fsync=off", "-l", str(self.dir / "log"), "-w", "start"],
                       check=True, capture_output=True)

    def stop(self):
        subprocess.run([TOOLS["pg_ctl"], "-D", str(self.dir / "data"), "-m", "immediate", "stop"], capture_output=True)
        shutil.rmtree(self.dir, ignore_errors=True)

    def psql(self, db, *args, stdin=None, check=True):
        cmd = [TOOLS["psql"], "-h", str(self.sock), "-p", self.port, "-U", "postgres", "-d", db, "-X", "-q", "-tA", *args]
        res = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
        if check and res.returncode != 0:
            raise RuntimeError(res.stderr)
        return res

    def fresh_db(self) -> str:
        name = "t" + uuid.uuid4().hex[:8]
        self.psql("postgres", "-c", f"create database {name}")
        self.psql(name, "-v", "ON_ERROR_STOP=1", "-f", str(SQL_DIR / "supabase_stub.sql"))
        for f in [*MIGRATIONS, SEED]:
            self.psql(name, "-v", "ON_ERROR_STOP=1", "-f", str(f))
        return name


@pytest.fixture(scope="module")
def cluster():
    c = Cluster()
    c.start()
    yield c
    c.stop()


def test_all_migrations_apply_and_every_table_has_rls(cluster):
    db = cluster.fresh_db()
    assert cluster.psql(db, "-c", "select count(*) from pg_tables where schemaname='public' and not rowsecurity").stdout.strip() == "0"
    leaked = cluster.psql(db, "-c", "select string_agg(p.proname, ',') from pg_proc p join pg_namespace n on n.oid=p.pronamespace "
                          "where n.nspname='public' and p.proname in ('place_order','cancel_order','apply_payment_event','transition_vendor_order','apply_refund_result') "
                          "and has_function_privilege('anon', p.oid, 'execute')").stdout.strip()
    assert leaked == ""      # none of the money/stock functions is callable by anon


def test_order_scenarios(cluster):
    db = cluster.fresh_db()
    res = cluster.psql(db, "-f", str(SQL_DIR / "orders_scenarios.sql"), check=False)
    lines = [ln for ln in (res.stdout + res.stderr).splitlines() if ln.startswith(("PASS ", "FAIL ")) or "ERROR:" in ln]
    failures = [ln for ln in lines if not ln.startswith("PASS ")]
    assert not failures, "\n".join(failures)
    assert sum(ln.startswith("PASS ") for ln in lines) >= 90


# ---------------------------------------------------------------------------------------------------- concurrency
PAYLOAD_FN = """
create function public.t_payload(cust uuid, k text, m text default 'cod') returns jsonb language sql as $$
 select jsonb_build_object('customer_id',cust,'idempotency_key',k,'request_hash','h','payment_method',m,'provider',case when m='online' then 'testpay' end,
  'delivery_address','{}'::jsonb,'subtotal',1000,'delivery_charge',0,'discount_amount',0,'total_amount',1000,
  'vendor_orders',jsonb_build_array(jsonb_build_object('vendor_id',(select id from public.vendor_profiles),'vendor_name','V','subtotal',1000,'delivery_charge',0,
  'discount_amount',0,'total_amount',1000,'commission_amount',0,'items',jsonb_build_array(jsonb_build_object('product_id','10000000-0000-0000-0000-000000000001',
  'unit_price',1000,'quantity',1,'name','B','condition','new','commission_amount',0))))) $$;
"""


@pytest.fixture
def shop(cluster):
    db = cluster.fresh_db()
    cluster.psql(db, "-v", "ON_ERROR_STOP=1", stdin=f"""
insert into auth.users (id,email,raw_user_meta_data) select ('00000000-0000-0000-0000-0000000001'||lpad(g::text,2,'0'))::uuid,'c'||g||'@x.t','{{}}' from generate_series(1,30) g;
insert into auth.users (id,email,raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000a1','v@x.t','{{"role":"vendor"}}');
insert into public.vendor_profiles (user_id,business_name,business_types,address_line1,city,state,postal_code,contact_phone,verification_status)
 values ('00000000-0000-0000-0000-0000000000a1','V','{{bicycle_shop}}','a','b','c','d','+919800000001','approved');
insert into public.products (id,vendor_id,category_id,product_type,name,condition,price,stock_quantity,approval_status)
 select '10000000-0000-0000-0000-000000000001',v.id,c.id,'new_cycle','Bikes','new',1000,3,'approved' from public.vendor_profiles v, public.categories c where c.slug='new-cycles';
{PAYLOAD_FN}""")

    def run_parallel(sqls):
        with ThreadPoolExecutor(max_workers=len(sqls)) as ex:
            return list(ex.map(lambda s: cluster.psql(db, "-c", s, check=False), sqls))

    return type("Shop", (), {"db": db, "q": lambda self, sql: cluster.psql(db, "-c", sql).stdout.strip(), "par": staticmethod(run_parallel)})()


def cust(i):
    return f"00000000-0000-0000-0000-0000000001{i:02d}"


def test_concurrent_checkouts_never_oversell(shop):
    """12 customers race for the last 3 units."""
    out = shop.par([f"select public.place_order(public.t_payload('{cust(i)}','race-key-{i:03d}'))" for i in range(1, 13)])
    ok = sum("order_id" in r.stdout for r in out)
    refused = sum("insufficient_stock" in r.stderr for r in out)
    assert (ok, refused) == (3, 9)
    assert shop.q("select stock_quantity from public.products") == "0"
    assert shop.q("select count(*) from public.orders") == "3"


def test_parallel_duplicate_idempotency_key_creates_one_order(shop):
    shop.q("update public.products set stock_quantity = 10")
    out = shop.par([f"select public.place_order(public.t_payload('{cust(1)}','same-key-0001'))" for _ in range(8)])
    assert all("order_id" in r.stdout for r in out) and sum('"replay": true' in r.stdout for r in out) == 7
    assert shop.q("select count(*) from public.orders") == "1"
    assert shop.q("select stock_quantity from public.products") == "9"


def test_parallel_cancellations_restore_stock_once(shop):
    shop.q("update public.products set stock_quantity = 10")
    shop.q(f"select public.place_order(public.t_payload('{cust(1)}','cancel-key-001'))")
    oid = shop.q("select id from public.orders")
    out = shop.par([f"select public.cancel_order('{oid}','{cust(1)}','customer','dup')" for _ in range(6)])
    assert sum("vendor_orders_cancelled" in r.stdout for r in out) == 1 and sum("not_cancellable" in r.stderr for r in out) == 5
    assert shop.q("select stock_quantity from public.products") == "10"


def test_parallel_duplicate_webhooks_apply_once(shop):
    shop.q("update public.products set stock_quantity = 10")
    shop.q(f"select public.place_order(public.t_payload('{cust(2)}','online-key-001','online'))")
    shop.q("select public.attach_provider_order((select id from public.payments), 'testpay', 'po_race')")
    ev = '{"provider":"testpay","event_id":"same-evt","event_type":"payment.succeeded","provider_order_id":"po_race","amount":1000,"currency":"INR"}'
    out = shop.par([f"select public.apply_payment_event('{ev}')" for _ in range(8)])
    assert sum('"outcome": "applied"' in r.stdout for r in out) == 1 and sum("duplicate" in r.stdout for r in out) == 7
    assert shop.q("select count(*) from public.payment_events") == "1"
    assert shop.q("select count(*) from public.notifications where title = 'Payment received'") == "1"


def test_parallel_refunds_cannot_exceed_paid_amount(shop):
    shop.q("update public.products set stock_quantity = 10")
    shop.q(f"select public.place_order(public.t_payload('{cust(3)}','online-key-002','online'))")
    shop.q("select public.attach_provider_order((select id from public.payments), 'testpay', 'po_r')")
    shop.q("""select public.apply_payment_event('{"provider":"testpay","event_id":"e","event_type":"payment.succeeded","provider_order_id":"po_r","amount":1000,"currency":"INR"}')""")
    pid = shop.q("select id from public.payments")
    out = shop.par([f"select public.cm_create_refund('{pid}', 400, 'race', null, null, 'rr-{i}', null)" for i in range(4)])
    assert sum("refund_exceeds" in r.stderr for r in out) == 2
    assert float(shop.q(f"select sum(amount) from public.refunds where payment_id = '{pid}'")) <= 1000


def test_webhook_racing_cancellation_never_deadlocks_or_corrupts(shop):
    shop.q("update public.products set stock_quantity = 1000")
    rounds = 8
    for i in range(1, rounds + 1):
        shop.q(f"select public.place_order(public.t_payload('{cust(i)}','race2-key-{i:03d}','online'))")
        shop.q(f"select public.attach_provider_order((select p.id from public.payments p join public.orders o on o.id=p.order_id where o.idempotency_key='race2-key-{i:03d}'), 'testpay', 'po-{i}')")
        oid = shop.q(f"select id from public.orders where idempotency_key='race2-key-{i:03d}'")
        ev = f'{{"provider":"testpay","event_id":"ev-{i}","event_type":"payment.succeeded","provider_order_id":"po-{i}","amount":1000,"currency":"INR"}}'
        out = shop.par([f"select public.apply_payment_event('{ev}')", f"select public.cancel_order('{oid}','{cust(i)}','customer','race')"])
        assert not any("deadlock" in r.stderr.lower() for r in out)
    # every order ends cancelled, every paid one has a refund request, stock fully returned
    assert shop.q("select count(*) from public.orders where status <> 'cancelled'") == "0"
    assert shop.q("select count(*) from public.orders o join public.payments p on p.order_id=o.id where p.status='successful' and not exists (select 1 from public.refunds r where r.payment_id=p.id)") == "0"
    assert shop.q("select stock_quantity from public.products") == "1000"


# ---------------------------------------------------------------------------------------------------- Step 6: servicing
def test_service_scenarios(cluster):
    db = cluster.fresh_db()
    res = cluster.psql(db, "-f", str(SQL_DIR / "services_scenarios.sql"), check=False)
    lines = [ln for ln in (res.stdout + res.stderr).splitlines() if ln.startswith(("PASS ", "FAIL ")) or "ERROR:" in ln]
    failures = [ln for ln in lines if not ln.startswith("PASS ")]
    assert not failures, "\n".join(failures)
    assert sum(ln.startswith("PASS ") for ln in lines) >= 60


@pytest.fixture
def svc_shop(cluster):
    db = cluster.fresh_db()
    cluster.psql(db, "-v", "ON_ERROR_STOP=1", stdin="""
insert into auth.users (id,email,raw_user_meta_data) select ('00000000-0000-0000-0000-0000000001'||lpad(g::text,2,'0'))::uuid,'c'||g||'@x.t','{}' from generate_series(1,12) g;
insert into auth.users (id,email,raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000a1','v@x.t','{"role":"vendor"}');
insert into public.vendor_profiles (user_id,business_name,business_types,address_line1,city,state,postal_code,contact_phone,verification_status,pickup_available)
 values ('00000000-0000-0000-0000-0000000000a1','V','{service_provider}','a','b','c','d','+919800000001','approved',true);
insert into public.vendor_services (id,vendor_id,service_category_id,name,price,max_bookings_per_slot)
 select '30000000-0000-0000-0000-000000000001', v.id, c.id, 'Tune-up', 400, 2 from public.vendor_profiles v, public.service_categories c where c.slug='general-servicing';
create function public.t_bk(cust uuid, day date) returns jsonb language sql as $$
 select jsonb_build_object('customer_id',cust,'service_id','30000000-0000-0000-0000-000000000001','issue_description','Needs a tune-up please','preferred_date',day,
   'slot_start','10:00','slot_end','11:00','needs_pickup_dropoff',false) $$;
""")

    def par(sqls):
        with ThreadPoolExecutor(max_workers=len(sqls)) as ex:
            return list(ex.map(lambda s: cluster.psql(db, "-c", s, check=False), sqls))

    return type("S", (), {"q": lambda self, sql: cluster.psql(db, "-c", sql).stdout.strip(), "par": staticmethod(par)})()


def test_parallel_accepts_never_exceed_slot_capacity(svc_shop):
    """8 pending bookings, capacity 2 per slot, all vendor accepts fired at once into the same confirmed slot."""
    for i in range(1, 9):
        svc_shop.q(f"select public.create_service_booking(public.t_bk('{cust(i)}', current_date + 5))")
    vendor = svc_shop.q("select id from public.vendor_profiles")
    ids = svc_shop.q("select string_agg(id::text, ',') from public.service_bookings").split(",")
    out = svc_shop.par([f"select public.accept_service_booking('{b}', '{vendor}', null, null, null, null, null)" for b in ids])
    assert sum("'accepted'" in r.stdout or '"status": "accepted"' in r.stdout for r in out) == 2
    assert sum("slot_full" in r.stderr for r in out) == 6
    assert svc_shop.q("select count(*) from public.service_bookings where status = 'accepted'") == "2"
    assert svc_shop.q("select count(*) from public.service_bookings where status = 'pending'") == "6"


def test_parallel_duplicate_bookings_create_one(svc_shop):
    out = svc_shop.par([f"select public.create_service_booking(public.t_bk('{cust(1)}', current_date + 6))" for _ in range(8)])
    assert sum("booking_id" in r.stdout for r in out) == 1 and sum("duplicate_booking" in r.stderr for r in out) == 7
    assert svc_shop.q("select count(*) from public.service_bookings") == "1"
    assert svc_shop.q("select count(*) from public.notifications where user_id = '00000000-0000-0000-0000-0000000001" + "01'") == "1"


def test_accept_racing_customer_cancel_ends_consistent(svc_shop):
    vendor = svc_shop.q("select id from public.vendor_profiles")
    for i in range(1, 9):
        svc_shop.q(f"select public.create_service_booking(public.t_bk('{cust(i)}', current_date + {10 + i}))")
    rows = svc_shop.q("select id || '|' || customer_id from public.service_bookings").splitlines()
    sqls = []
    for r in rows:
        b, c = r.split("|")
        sqls += [f"select public.accept_service_booking('{b}', '{vendor}', null, null, null, null, null)",
                 f"select public.transition_service_booking('{b}', null, 'cancelled', '{c}', 'customer', 'race')"]
    out = svc_shop.par(sqls)
    assert not any("deadlock" in r.stderr.lower() for r in out)
    assert svc_shop.q("select count(*) from public.service_bookings where status not in ('cancelled')") == svc_shop.q("select count(*) from public.service_bookings where status = 'accepted'")
    assert svc_shop.q("select count(*) from public.service_bookings where status = 'cancelled' and confirmed_date is not null") == "0"


# ---------------------------------------------------------------------------------------------------- Step 8: vendor dashboard aggregate
def test_vendor_dashboard_summary_matches_the_records(shop):
    shop.q("update public.products set stock_quantity = 10")
    vendor = shop.q("select id from public.vendor_profiles")
    for i in (1, 2, 3):
        shop.q(f"select public.place_order(public.t_payload('{cust(i)}','dash-key-{i:03d}'))")
    ids = shop.q("select string_agg(id::text, ',' order by created_at) from public.vendor_orders").split(",")
    shop.q(f"select public.transition_vendor_order('{ids[0]}', '{vendor}', 'accepted', null, 'vendor', null)")
    shop.q(f"select public.transition_vendor_order('{ids[1]}', '{vendor}', 'rejected', null, 'vendor', 'out of stock')")
    shop.q("select public.vendor_dashboard_summary((select id from public.vendor_profiles))")
    import json
    d = json.loads(shop.q(f"select public.vendor_dashboard_summary('{vendor}')::text"))
    assert d["orders"]["total"] == 3 and d["orders"]["by_status"] == {"accepted": 1, "rejected": 1, "pending": 1}
    assert d["orders"]["sales_total"] == 0 and d["products"]["total"] == 1 and d["products"]["active"] == 1
    assert d["bookings"]["total"] == 0 and d["settlements"] == {}
    # an unknown vendor sees nothing; the function is not callable by API roles
    other = json.loads(shop.q("select public.vendor_dashboard_summary('00000000-0000-0000-0000-00000000dead')::text"))
    assert other["orders"]["total"] == 0 and other["products"]["total"] == 0
    denied = shop.par([f"set role authenticated; select public.vendor_dashboard_summary('{vendor}')"])[0]
    assert "permission denied" in denied.stderr


# ---------------------------------------------------------------------------------------------------- Step 9: admin console aggregates
def test_admin_dashboard_summary_and_entity_counts(shop):
    import json
    shop.q("update public.products set stock_quantity = 10")
    for i in (1, 2, 3):
        shop.q(f"select public.place_order(public.t_payload('{cust(i)}','adm-key-{i:03d}'))")
    shop.q(f"update public.profiles set status = 'restricted' where id = '{cust(3)}'")
    ids = shop.q("select string_agg(id::text, ',' order by created_at) from public.orders").split(",")
    shop.q(f"update public.orders set status = 'completed' where id = '{ids[0]}'")
    shop.q(f"update public.orders set status = 'cancelled' where id = '{ids[1]}'")
    d = json.loads(shop.q("select public.admin_dashboard_summary(current_date - 6, current_date)::text"))
    assert d["customers"]["total"] == 30 and d["customers"]["by_status"] == {"active": 29, "restricted": 1}
    assert d["customers"]["new_in_period"] == 30, "all customers were created today"
    assert d["vendors"]["total"] == 1 and d["vendors"]["by_verification"] == {"approved": 1} and d["vendors"]["by_account_status"] == {"active": 1}
    assert d["orders"]["total"] == 3 and d["orders"]["by_status"] == {"completed": 1, "cancelled": 1, "confirmed": 1}
    assert d["orders"]["value_completed"] == 1000 and d["orders"]["value_confirmed"] == 1000
    assert d["bookings"] == {"total": 0, "by_status": {}}
    days = d["series"]["orders"]
    assert len(days) == 7 and days[-1]["count"] == 3 and days[-1]["value"] == 2000, "cancelled orders are not counted as value"
    assert all(x["count"] == 0 and x["value"] == 0 for x in days[:-1]), "empty days are real zeros, not invented values"
    assert len(d["series"]["customers"]) == 7 and d["series"]["customers"][-1]["count"] == 30
    counts = json.loads(shop.q(f"select public.admin_entity_counts('customer', array['{cust(1)}','{cust(9)}']::uuid[])::text"))
    assert counts[cust(1)] == {"orders": 1, "bookings": 0} and counts[cust(9)] == {"orders": 0, "bookings": 0}
    vendor = shop.q("select id from public.vendor_profiles")
    assert json.loads(shop.q(f"select public.admin_entity_counts('vendor', array['{vendor}']::uuid[])::text"))[vendor] == {"products": 1, "orders": 3, "bookings": 0}
    assert json.loads(shop.q("select public.admin_entity_counts('nonsense', array[]::uuid[])::text")) == {}
    for fn in ("public.admin_dashboard_summary(current_date, current_date)", "public.admin_entity_counts('customer', array[]::uuid[])"):
        assert "permission denied" in shop.par([f"set role authenticated; select {fn}"])[0].stderr


# ---------------------------------------------------------------------------------------------------- Step 10: announcements, reports, notification check
def _admin(shop):
    shop.q(f"update public.profiles set role = 'admin' where id = '{cust(30)}'")
    return cust(30)


def test_admin_announcement_function_is_atomic_targeted_and_counted(shop):
    import json
    admin = _admin(shop)
    vendor_user = "00000000-0000-0000-0000-0000000000a1"
    sent = json.loads(shop.q(f"select public.admin_send_announcement('Festive sale','Up to 20% off.','promotion','customers',null,'{admin}')::text"))
    assert sent["recipient_count"] == 29, "30 customer rows minus the one promoted to admin; vendors are not customers"
    assert shop.q(f"select count(*) from public.notifications where announcement_id = '{sent['id']}'") == "29"
    assert shop.q(f"select count(*) from public.notifications where announcement_id = '{sent['id']}' and user_id = '{vendor_user}'") == "0"
    shop.q(f"update public.notifications set is_read = true where announcement_id = '{sent['id']}' and user_id in ('{cust(1)}','{cust(2)}','{cust(3)}')")
    stats = json.loads(shop.q(f"select public.admin_announcement_stats(array['{sent['id']}']::uuid[])::text"))
    assert stats[sent["id"]] == {"delivered": 29, "read": 3, "push_sent": 0, "push_failed": 0, "push_pending": 29}
    assert json.loads(shop.q("select public.admin_announcement_stats(array[]::uuid[])::text")) == {}
    # vendors / specific (admins and unknown ids are never recipients)
    v = json.loads(shop.q(f"select public.admin_send_announcement('Notice','Marketplace update','announcement','vendors',null,'{admin}')::text"))
    assert v["recipient_count"] == 1
    s = json.loads(shop.q(f"select public.admin_send_announcement('Hello','Just you two','system','specific',array['{cust(1)}','{vendor_user}','{admin}','{uuid.uuid4()}']::uuid[],'{admin}')::text"))
    assert s["recipient_count"] == 2
    # inactive accounts are skipped; with nobody left the whole call fails and leaves NO announcement behind
    before = shop.q("select count(*) from public.announcements")
    shop.q("update public.profiles set status = 'inactive' where role = 'customer'")
    res = shop.par([f"select public.admin_send_announcement('Nobody','Nobody home','announcement','customers',null,'{admin}')"])[0]
    assert "CM:no_recipients" in res.stderr
    assert shop.q("select count(*) from public.announcements") == before
    assert "CM:invalid_audience" in shop.par([f"select public.admin_send_announcement('Bad','Bad audience','announcement','everyone',null,'{admin}')"])[0].stderr
    # constraints on the table itself
    assert "violates check constraint" in shop.par(["insert into public.announcements (title, message, type, audience) values ('x', 'long enough message', 'announcement', 'customers')"])[0].stderr
    assert "violates check constraint" in shop.par(["insert into public.announcements (title, message, type, audience) values ('Title ok', 'long enough message', 'order', 'customers')"])[0].stderr
    for fn in (f"public.admin_send_announcement('Title','Message ok','system','vendors',null,'{admin}')", "public.admin_announcement_stats(array[]::uuid[])", "public.admin_report('orders', current_date, current_date)"):
        assert "permission denied" in shop.par([f"set role authenticated; select {fn}"])[0].stderr


def test_notification_related_type_now_allows_vendor_decisions(shop):
    """Regression: Step 9 stored related_type 'vendor_application', which the original CHECK rejected on a real database."""
    vendor_user = "00000000-0000-0000-0000-0000000000a1"
    shop.q(f"insert into public.notifications (user_id, type, title, message, related_type, related_id) values ('{vendor_user}', 'system', 'Approved', 'ok', 'vendor_application', gen_random_uuid())")
    shop.q(f"insert into public.notifications (user_id, type, title, message, related_type, related_id) values ('{vendor_user}', 'system', 'Service off', 'ok', 'vendor_service', gen_random_uuid())")
    assert "violates check constraint" in shop.par([f"insert into public.notifications (user_id, type, title, message, related_type, related_id) values ('{vendor_user}', 'system', 'x', 'y', 'bogus', gen_random_uuid())"])[0].stderr


def test_admin_reports_match_the_records(shop):
    import json
    shop.q("update public.products set stock_quantity = 10")
    for i in (1, 2, 3):
        shop.q(f"select public.place_order(public.t_payload('{cust(i)}','rep-key-{i:03d}'))")
    ids = shop.q("select string_agg(id::text, ',' order by created_at) from public.orders").split(",")
    shop.q(f"update public.orders set status = 'cancelled' where id = '{ids[2]}'")
    for vo in shop.q(f"select string_agg(id::text, ',') from public.vendor_orders where order_id in ('{ids[0]}', '{ids[1]}')").split(","):
        for st in ("accepted", "preparing", "ready_for_dispatch", "delivered"):
            shop.q(f"select public.transition_vendor_order('{vo}', null, '{st}', '{cust(30)}', 'admin', null)")
    shop.q(f"update public.vendor_orders set commission_amount = 100 where order_id in ('{ids[0]}', '{ids[1]}')")
    shop.q(f"update public.payments set status = 'successful', paid_at = now() where order_id = '{ids[0]}'")
    rep = lambda kind, a="current_date - 2", b="current_date": json.loads(shop.q(f"select public.admin_report('{kind}', {a}, {b})::text"))  # noqa: E731

    o = rep("orders")
    assert o["total"] == 3 and o["by_status"] == {"completed": 2, "cancelled": 1} and o["by_payment_method"] == {"cod": 3} and o["value"] == 2000
    assert len(o["series"]) == 3 and o["series"][-1] == {"day": o["series"][-1]["day"], "count": 3, "value": 2000} and o["series"][0]["count"] == 0
    s = rep("sales")
    assert s["delivered_orders"] == 2 and s["gross_sales"] == 2000 and s["commission"] == 200 and s["discounts"] == 0
    assert s["by_vendor"][0]["vendor_name"] == "V" and s["by_vendor"][0]["orders"] == 2 and s["by_vendor"][0]["sales"] == 2000
    assert s["by_product"][0]["product_name"] == "B" and s["by_product"][0]["units"] == 2
    assert rep("sales", "current_date + 5", "current_date + 6")["delivered_orders"] == 0, "outside the period nothing is counted"
    p = rep("payments")
    assert p["total"] == 3 and p["collected"] == 1000 and p["collected_by_method"]["cod"] == {"count": 1, "amount": 1000} and p["commission"] == 200
    assert p["by_status"]["successful"]["count"] == 1 and p["by_status"]["pending"]["count"] == 2 and p["refunded"] == 0 and p["refunds_by_status"] == {}
    assert sum(d["value"] for d in p["series"]) == 1000
    v = rep("vendors")
    assert v["total"] == 1 and v["by_verification"] == {"approved": 1} and v["performance"][0]["orders_delivered"] == 2 and v["performance"][0]["sales"] == 2000
    c = rep("customers")
    assert c["total"] == 30 and c["active_in_period"] == 3 and c["orders_in_period"] == 3 and c["new_in_period"] == 30 and len(c["top_customers"]) == 3
    sv = rep("services")
    assert sv["total"] == 0 and sv["by_status"] == {} and sv["completed_value"] == 0 and sv["pickup"]["requests"] == 0 and len(sv["series"]) == 3
    assert "CM:invalid_report" in shop.par(["select public.admin_report('nonsense', current_date, current_date)"])[0].stderr


# ---------------------------------------------------------------------------------------------------- Step 11: device tokens, push outbox, events
VENDOR_USER = "00000000-0000-0000-0000-0000000000a1"


def tok(n):
    return f"fcm-token-{n:04d}-abcdefghijklmnopqrstuvwxyz"


def claim(shop, limit=50):
    import json
    return json.loads(shop.q(f"select public.claim_pending_pushes({limit}, 5, interval '1 day')::text"))


def test_device_tokens_belong_to_one_user_and_are_invisible_to_clients(shop):
    q = shop.q
    q(f"select public.register_device_token('{cust(1)}', '{tok(1)}', 'android', 'customer', 'Pixel 7', '1.0.0')")
    assert q("select count(*) from public.device_tokens where is_active") == "1"
    q(f"select public.register_device_token('{cust(1)}', '{tok(1)}', 'android', 'customer', 'Pixel 7', '1.0.1')")           # refresh: same row
    assert q("select count(*) from public.device_tokens") == "1" and q("select app_version from public.device_tokens") == "1.0.1"
    q(f"select public.register_device_token('{cust(2)}', '{tok(1)}', 'android', 'customer', null, null)")                       # same phone, another account: the token moves
    assert q(f"select user_id from public.device_tokens where token = '{tok(1)}'") == cust(2) and q("select count(*) from public.device_tokens") == "1"
    assert q(f"select public.deactivate_device_token('{cust(1)}', '{tok(1)}')") == "0", "only the current owner can unregister it"
    assert q("select is_active from public.device_tokens") == "t"
    assert q(f"select public.deactivate_device_token('{cust(2)}', '{tok(1)}')") == "1" and q("select is_active from public.device_tokens") == "f"
    for i in range(2, 15):                                                                                                       # a user keeps at most 10 active devices
        q(f"select public.register_device_token('{cust(3)}', '{tok(i)}', 'android', 'customer', null, null)")
    assert q(f"select count(*) from public.device_tokens where user_id = '{cust(3)}' and is_active") == "10"
    assert "violates check constraint" in shop.par([f"select public.register_device_token('{cust(3)}', 'short', 'android', 'customer', null, null)"])[0].stderr
    assert "violates check constraint" in shop.par([f"select public.register_device_token('{cust(3)}', '{tok(99)}', 'symbian', 'customer', null, null)"])[0].stderr
    # clients (anon / authenticated) can neither read nor write tokens, nor call the functions
    for role in ("anon", "authenticated"):
        for sql in ("select token from public.device_tokens", f"insert into public.device_tokens (user_id, token, platform, app) values ('{cust(1)}', '{tok(50)}', 'android', 'customer')",
                    f"select public.register_device_token('{cust(1)}', '{tok(51)}', 'android', 'customer', null, null)", "select public.claim_pending_pushes(5, 5, interval '1 day')"):
            assert "permission denied" in shop.par([f"set role {role}; set request.jwt.claim.sub = '{cust(1)}'; {sql}"])[0].stderr, (role, sql)


def test_push_outbox_lifecycle_claims_once_retries_and_gives_up(shop):
    import json
    q = shop.q
    q("update public.products set stock_quantity = 10")
    q(f"select public.register_device_token('{cust(1)}', '{tok(1)}', 'android', 'customer', null, null)")
    q(f"select public.register_device_token('{VENDOR_USER}', '{tok(2)}', 'android', 'vendor', null, null)")
    q(f"select public.place_order(public.t_payload('{cust(1)}','push-key-001'))")
    assert q("select count(*) from public.notifications where push_status = 'pending'") == "2", "customer 'Order placed' + vendor 'New order', created in the same transaction"
    rows = claim(shop)
    assert {r["user_id"] for r in rows} == {cust(1), VENDOR_USER} and all(len(r["tokens"]) == 1 for r in rows)
    assert all(r["attempts"] == 1 for r in rows)
    assert claim(shop) == [], "claimed rows are leased: a second worker gets nothing"
    by_user = {r["user_id"]: r for r in rows}
    q(f"select public.finish_push('{by_user[cust(1)]['id']}', 'sent', null, null, null)")
    q(f"select public.finish_push('{by_user[VENDOR_USER]['id']}', 'pending', 'FCM unavailable', 3600, null)")
    assert q("select push_status || ':' || push_attempts from public.notifications where user_id = '" + VENDOR_USER + "'") == "pending:1"
    assert q("select push_sent_at is not null from public.notifications where user_id = '" + cust(1) + "'") == "t"
    assert claim(shop) == [], "a retry waits for its back-off"
    q("update public.notifications set push_next_at = now() - interval '1 second' where push_status = 'pending'")
    again = claim(shop)
    assert [r["attempts"] for r in again] == [2]
    q(f"select public.finish_push('{again[0]['id']}', 'pending', 'FCM unavailable', 1, null)")
    for _ in range(3):
        q("update public.notifications set push_next_at = now() - interval '1 second' where push_status = 'pending'")
        r = claim(shop)
        q(f"select public.finish_push('{r[0]['id']}', 'pending', 'FCM unavailable', 1, null)")
    q("update public.notifications set push_next_at = now() - interval '1 second' where push_status = 'pending'")
    assert claim(shop) == []
    assert q("select push_status from public.notifications where user_id = '" + VENDOR_USER + "'") == "failed", "gives up after 5 attempts"
    assert "CM:invalid_push_status" in shop.par([f"select public.finish_push('{rows[0]['id']}', 'bogus', null, null, null)"])[0].stderr


def test_push_skips_inactive_accounts_expires_old_rows_and_invalid_tokens_are_deactivated(shop):
    q = shop.q
    q("update public.products set stock_quantity = 10")
    q(f"select public.register_device_token('{cust(1)}', '{tok(1)}', 'android', 'customer', null, null)")
    q(f"select public.register_device_token('{cust(1)}', '{tok(2)}', 'android', 'customer', null, null)")
    q(f"select public.place_order(public.t_payload('{cust(1)}','push-key-002'))")
    q("update public.notifications set created_at = now() - interval '3 days' where user_id = '" + cust(1) + "'")
    q(f"select public.place_order(public.t_payload('{cust(1)}','push-key-003'))")
    q(f"update public.profiles set status = 'inactive' where id = '{VENDOR_USER}'")
    fresh = [r for r in claim(shop) if r["user_id"] == cust(1)]
    assert q("select count(*) from public.notifications where user_id = '" + cust(1) + "' and push_status = 'expired'") == "1"
    assert q("select count(*) from public.notifications where user_id = '" + VENDOR_USER + "' and push_status = 'skipped'") == "2"
    assert len(fresh[0]["tokens"]) == 2
    bad = [t["id"] for t in fresh[0]["tokens"] if t["token"] == tok(1)][0]
    q(f"select public.finish_push('{fresh[0]['id']}', 'sent', null, null, array['{bad}']::uuid[])")
    assert q(f"select is_active from public.device_tokens where token = '{tok(1)}'") == "f" and q(f"select is_active from public.device_tokens where token = '{tok(2)}'") == "t"


def test_parallel_workers_never_claim_the_same_notification(shop):
    import json
    q = shop.q
    q("update public.products set stock_quantity = 100")
    for i in range(1, 11):
        q(f"select public.place_order(public.t_payload('{cust(i)}','par-key-{i:03d}'))")
    total = int(q("select count(*) from public.notifications where push_status = 'pending'"))
    out = shop.par(["select public.claim_pending_pushes(7, 5, interval '1 day')::text"] * 8)
    ids = [r["id"] for res in out for r in json.loads(res.stdout.strip())]
    assert len(ids) == total == len(set(ids)), "every pending row is claimed exactly once across 8 parallel workers"


def test_vendor_is_told_when_someone_else_cancels_and_when_a_product_is_moderated(shop):
    q = shop.q
    q("update public.products set stock_quantity = 10")
    q(f"select public.place_order(public.t_payload('{cust(1)}','evt-key-001'))")
    oid = q("select id from public.orders")
    q(f"select public.cancel_order('{oid}', '{cust(1)}', 'customer', 'Changed my mind')")
    msgs = q(f"select string_agg(title || '|' || coalesce(related_type, ''), ';') from public.notifications where user_id = '{VENDOR_USER}' and title = 'Order cancelled'")
    assert msgs == "Order cancelled|vendor_order"
    assert q(f"select message like '%Changed my mind%' from public.notifications where user_id = '{VENDOR_USER}' and title = 'Order cancelled'") == "t"
    # the vendor's own rejection is not echoed back to them
    q(f"select public.place_order(public.t_payload('{cust(2)}','evt-key-002'))")
    vo = q(f"select id from public.vendor_orders where order_id = (select id from public.orders where customer_id = '{cust(2)}')")
    q(f"select public.transition_vendor_order('{vo}', null, 'rejected', '{VENDOR_USER}', 'vendor', 'Out of stock')")
    assert q(f"select count(*) from public.notifications where user_id = '{VENDOR_USER}' and title = 'Order cancelled'") == "1"
    # product moderation
    pid = "10000000-0000-0000-0000-000000000001"
    q(f"update public.products set approval_status = 'pending' where id = '{pid}'")
    q(f"update public.products set approval_status = 'rejected', review_notes = 'Photos unclear' where id = '{pid}'")
    q(f"update public.products set approval_status = 'approved' where id = '{pid}'")
    assert q(f"select string_agg(title, ',' order by created_at) from public.notifications where user_id = '{VENDOR_USER}' and related_type = 'product'") == "Product rejected,Product approved"
    assert q(f"select count(*) from public.notifications where user_id = '{VENDOR_USER}' and related_type = 'product' and message like '%Photos unclear%'") == "1"


def test_users_cannot_tamper_with_the_push_columns_of_their_own_notifications(shop):
    q = shop.q
    q("update public.products set stock_quantity = 10")
    q(f"select public.place_order(public.t_payload('{cust(1)}','tamper-001'))")
    nid = q(f"select id from public.notifications where user_id = '{cust(1)}'")
    as_user = f"set role authenticated; set request.jwt.claim.sub = '{cust(1)}'; "
    ok = shop.par([as_user + f"update public.notifications set is_read = true where id = '{nid}'"])[0]
    assert ok.returncode == 0 and q(f"select is_read from public.notifications where id = '{nid}'") == "t"
    for col, val in (("push_status", "'sent'"), ("push_attempts", "7"), ("push_error", "'x'"), ("title", "'hacked'")):
        res = shop.par([as_user + f"update public.notifications set {col} = {val} where id = '{nid}'"])[0]
        assert "only the read state" in res.stderr, col


def test_push_outcomes_reach_the_announcement_stats_and_the_admin_summary(shop):
    import json
    q = shop.q
    admin = cust(30)
    q(f"update public.profiles set role = 'admin' where id = '{admin}'")
    q(f"select public.register_device_token('{cust(1)}', '{tok(1)}', 'android', 'customer', null, null)")
    sent = json.loads(q(f"select public.admin_send_announcement('Festive sale','Big offers today','promotion','customers',null,'{admin}')::text"))
    rows = claim(shop, 100)
    assert len(rows) == 29
    for r in rows:
        status = "sent" if r["user_id"] == cust(1) else "skipped"
        q(f"select public.finish_push('{r['id']}', '{status}', null, null, null)")
    stats = json.loads(q(f"select public.admin_announcement_stats(array['{sent['id']}']::uuid[])::text"))[sent["id"]]
    assert stats == {"delivered": 29, "read": 0, "push_sent": 1, "push_failed": 0, "push_pending": 0}
    summary = json.loads(q("select public.admin_push_status()::text"))
    assert summary["by_status"] == {"sent": 1, "skipped": 28} and summary["active_devices"] == {"customer": 1} and summary["oldest_pending"] is None
    for fn in ("public.admin_push_status()", "public.finish_push(gen_random_uuid(), 'sent', null, null, null)"):
        assert "permission denied" in shop.par([f"set role authenticated; select {fn}"])[0].stderr


# ---------------------------------------------------------------------------------------------------- Step 11: Storage buckets and policies (real PostgreSQL RLS on storage.objects)
def test_storage_buckets_are_configured_and_every_policy_enforces_ownership(svc_shop):
    """Runs migration 09's policies against the stubbed `storage.objects` table. It proves the POLICY LOGIC; real Supabase Storage (signed URLs, the HTTP API,
    MIME sniffing) is not exercised here."""
    s, q = svc_shop, svc_shop.q
    admin, c1, c2 = cust(12), cust(1), cust(2)
    q(f"update public.profiles set role = 'admin' where id = '{admin}'")
    q(f"select public.create_service_booking(public.t_bk('{c1}', current_date + 3))")
    booking = q("select id from public.service_bookings")
    assert q("select string_agg(id || ':' || public || ':' || file_size_limit || ':' || array_to_string(allowed_mime_types, '|'), ';' order by id) from storage.buckets") == (
        "avatars:false:5242880:image/jpeg|image/png|image/webp;banners:true:5242880:image/jpeg|image/png|image/webp;product-images:true:5242880:image/jpeg|image/png|image/webp;"
        "service-images:false:5242880:image/jpeg|image/png|image/webp;shop-images:true:5242880:image/jpeg|image/png|image/webp")

    def run(who, sql):
        role = "anon" if who is None else "authenticated"
        claim = "" if who is None else f"set request.jwt.claim.sub = '{who}'; "
        return s.par([f"set role {role}; {claim}{sql}"])[0]

    def put(who, bucket, name):
        return "row-level security" not in run(who, f"insert into storage.objects (bucket_id, name, owner) values ('{bucket}', '{name}', null)").stderr

    def see(who, bucket, name=None):
        where = f" and name = '{name}'" if name else ""
        return int(run(who, f"select count(*) from storage.objects where bucket_id = '{bucket}'{where}").stdout.strip() or 0)

    # product images: public bucket, an approved vendor writes only into their own folder
    assert put(VENDOR_USER, "product-images", f"{VENDOR_USER}/p1/a.jpg")
    assert not put(VENDOR_USER, "product-images", f"{c1}/p1/a.jpg"), "another user's folder"
    assert not put(c1, "product-images", f"{c1}/p1/a.jpg"), "customers cannot upload product images"
    assert not put(None, "product-images", "anon/a.jpg")
    assert see(None, "product-images") == 1 and see(c1, "product-images") == 1, "public read for everyone"
    # shop images: any vendor-role account (even before approval) writes to its own folder; customers cannot
    assert put(VENDOR_USER, "shop-images", f"{VENDOR_USER}/shop.jpg") and not put(c1, "shop-images", f"{c1}/shop.jpg") and see(None, "shop-images") == 1
    # banners: admin writes, everyone reads
    assert put(admin, "banners", "banners/b1.jpg")
    assert not put(VENDOR_USER, "banners", "banners/v.jpg") and not put(c1, "banners", "banners/c.jpg") and not put(None, "banners", "banners/a.jpg")
    assert see(None, "banners") == 1
    # service images (private): the customer owns <uid>/<booking>/..., the booking's vendor and admins may read, nobody else
    own = f"{c1}/{booking}/engine.jpg"
    assert put(c1, "service-images", own)
    assert not put(c2, "service-images", f"{c1}/{booking}/hack.jpg"), "writing into someone else's folder"
    assert not put(VENDOR_USER, "service-images", f"{VENDOR_USER}/{booking}/x.jpg"), "vendors cannot upload customer photos"
    assert see(c1, "service-images") == 1 and see(admin, "service-images") == 1 and see(VENDOR_USER, "service-images") == 1
    assert see(c2, "service-images") == 0 and see(None, "service-images") == 0, "private bucket: other customers and anonymous users see nothing"
    q(f"insert into storage.objects (bucket_id, name) values ('service-images', '{c2}/{'00000000-0000-0000-0000-00000000dead'}/other.jpg')")
    assert see(VENDOR_USER, "service-images") == 1, "the vendor sees only photos of THEIR bookings, not other bookings' photos"
    # avatars (private): owner only, admin may read
    assert put(c1, "avatars", f"{c1}/me.jpg") and not put(c2, "avatars", f"{c1}/me2.jpg")
    assert see(c1, "avatars") == 1 and see(c2, "avatars") == 0 and see(admin, "avatars") == 1 and see(None, "avatars") == 0 and see(VENDOR_USER, "avatars") == 0
    # nobody but the owner can delete or replace
    assert run(c2, f"delete from storage.objects where bucket_id = 'service-images' and name = '{own}'").stdout.strip() in ("", "DELETE 0") and see(admin, "service-images", own) == 1
