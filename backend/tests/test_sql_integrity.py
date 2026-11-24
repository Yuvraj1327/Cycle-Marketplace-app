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
