"""Execute the real transport under Lua 5.4 with FiveM natives stubbed.
Requires lupa; only Cfx compound assignments are expanded for stock Lua.
"""
import json
import re
import unittest
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]

def ordinary_lua(source):
    return re.sub(r'(?m)^(\s*)([\w.]+)\s*([+-])=\s*(.*)$', r'\1\2 = \2 \3 (\4)', source)

class Runtime:
    def __init__(self, disk, max_queue=None):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.disk = disk
        self.requests = []
        self.request_details = []
        self.timers = []
        self.fail_storage = False
        def plain(value):
            if hasattr(value, 'items'):
                data = {k: plain(v) for k, v in value.items()}
                if data and all(isinstance(k, int) for k in data):
                    return [data[k] for k in sorted(data)]
                return data
            return value
        def save(data):
            if self.fail_storage: return self.lua.table_from({'error': 'disk full'})
            disk['data'] = data
            return self.lua.table_from({'ok': True})
        g = self.lua.globals()
        g.py_encode = lambda value: json.dumps(plain(value), separators=(',', ':'))
        g.py_decode = lambda value: self.lua.table_from(json.loads(value), recursive=True)
        g.py_save = save
        g.py_load = lambda: self.lua.table_from(disk)
        def http(endpoint, callback, method, body, headers, options):
            self.requests.append((body, callback))
            self.request_details.append((endpoint, plain(headers), plain(options)))
        g.py_http = http
        g.py_timer = lambda delay, callback: self.timers.append(callback)
        self.lua.execute('''
            json={encode=function(v) return py_encode(v) end,decode=function(v) return py_decode(v) end}
            function GetGameTimer() return 100000 end
            function GetCurrentResourceName() return 'test' end
            function GetConvar(name) if name=='vanishlogs_endpoint' then return 'https://logs.example.com' else return 'plog_prefix_secret' end end
            function GetResourceMetadata() return '1.0.0' end
            local counter=0
            function NewId() counter=counter+1 return 'id-'..counter end
            function UtcNow() return '2026-09-05T00:00:00Z' end
            function Warn(...) end function Debug(...) end function LogError(...) end
            function CreateThread(fn) end function Wait(ms) end
            PerformHttpRequest=py_http SetTimeout=py_timer
            exports={test={SavePendingLogs=function(_,v) return py_save(v) end,LoadPendingLogs=function() return py_load() end,SignLogBatch=function() return {} end}}
        ''')
        self.lua.execute((ROOT/'config.lua').read_text())
        g.Config.batch.maxEvents = 10
        if max_queue is not None: g.Config.batch.maxQueue = max_queue
        self.lua.execute((ROOT/'server/limits.lua').read_text())
        for filename in ['queue.lua', 'transport.lua']:
            self.lua.execute(ordinary_lua((ROOT/'server'/filename).read_text()))
        self.lua.execute('t=Transport.new(); t:Start()')
        self.t = g.t
    def event(self, name='stable'):
        self.lua.globals().event_id = name
        self.lua.execute("t:Enqueue({id=event_id,occurredAt='2026-09-05T00:00:00Z',category='system',action='test'})")
    def flush(self): self.lua.execute('t:Flush(true)')

class DeliveryTests(unittest.TestCase):
    def endpoint_runtime(self, endpoint, allow_local=False):
        runtime = Runtime({})
        runtime.lua.globals().test_endpoint = endpoint
        runtime.lua.globals().Config.allowLocalHttp = allow_local
        runtime.lua.execute('''
            function GetConvar(name)
                if name == 'vanishlogs_endpoint' then return test_endpoint end
                return 'plog_prefix_secret'
            end
        ''')
        runtime.event()
        runtime.flush()
        return runtime

    def test_https_sends_credentials_without_following_redirects(self):
        runtime = self.endpoint_runtime(' https://logs.example.com/prefix/ ')
        endpoint, headers, options = runtime.request_details[0]
        self.assertEqual(endpoint, 'https://logs.example.com/prefix/ingest/v1/events')
        self.assertEqual(headers['Authorization'], 'Bearer plog_prefix_secret')
        self.assertIs(options['followLocation'], False)
        runtime.requests[0][1](302, '')
        self.assertIsNotNone(runtime.t.inFlight)
        self.assertEqual(len(runtime.requests), 1)

    def test_http_is_refused_by_default_and_events_are_preserved(self):
        for endpoint in ('http://logs.example.com', 'http://127.0.0.1:8787', 'http://[::1]:8787'):
            with self.subTest(endpoint=endpoint):
                runtime = self.endpoint_runtime(endpoint)
                self.assertEqual(runtime.requests, [])
                self.assertEqual(runtime.t.queue.Size(runtime.t.queue), 1)
                self.assertIn('stable', runtime.disk['data'])
                runtime.lua.globals().Config.signRequests = False
                runtime.flush()
                self.assertEqual(runtime.requests, [])

    def test_local_http_requires_explicit_opt_in(self):
        for endpoint in ('http://127.0.0.1', 'http://127.0.0.1:8787', 'http://[::1]', 'http://[::1]:8787'):
            with self.subTest(endpoint=endpoint):
                self.assertEqual(len(self.endpoint_runtime(endpoint, allow_local=True).requests), 1)

    def test_local_http_opt_in_cannot_target_remote_or_ambiguous_urls(self):
        for endpoint in (
            'http://logs.example.com', 'http://192.168.1.1', 'http://localhost',
            'http://127.0.0.1.example.com', 'http://127.0.0.1@logs.example.com',
            'http://127.0.0.1:80@logs.example.com', 'http://[::1].example.com',
            'http://127.0.0.1\\@logs.example.com', 'http://2130706433',
            'https://user:password@logs.example.com', 'https://logs.example.com?key=value',
            'https://logs.example.com#fragment', 'https://logs.exa mple.com',
            'https://logs.example.com\n/path', 'ftp://127.0.0.1', 'https://',
        ):
            with self.subTest(endpoint=endpoint):
                self.assertEqual(self.endpoint_runtime(endpoint, allow_local=True).requests, [])

    def test_outage_then_restart_replays_exact_body(self):
        disk={}; first=Runtime(disk); first.event(); first.flush()
        body,callback=first.requests[0]; callback(503,'unavailable')
        second=Runtime(disk); self.assertEqual(second.t.recovered,1); second.flush()
        self.assertEqual(second.requests[0][0],body)
        second.requests[0][1](202,'{"accepted":1,"duplicates":0,"rejected":0}')
        third=Runtime(disk); self.assertEqual(third.t.recovered,0)
    def test_disk_failure_retains_logs_and_prevents_uncheckpointed_send(self):
        runtime=Runtime({}); runtime.fail_storage=True; runtime.event(); runtime.flush()
        self.assertEqual(len(runtime.requests),0); self.assertEqual(runtime.t.queue.Size(runtime.t.queue),1)
        self.assertIsNotNone(runtime.t.storageError)
    def test_timeout_retries_and_ignores_late_old_callback(self):
        runtime=Runtime({}); runtime.event(); runtime.flush()
        old=runtime.requests[0][1]; runtime.timers[0](); runtime.flush()
        self.assertEqual(len(runtime.requests),2)
        old(202,'{"accepted":1,"duplicates":0,"rejected":0}')
        self.assertIsNotNone(runtime.t.inFlight)
        runtime.requests[1][1](202,'{"accepted":0,"duplicates":1,"rejected":0}')
        self.assertIsNone(runtime.t.inFlight)
    def test_invalid_success_receipt_is_not_acknowledged(self):
        runtime=Runtime({}); runtime.event(); runtime.flush(); runtime.requests[0][1](200,'html')
        self.assertIsNotNone(runtime.t.inFlight)
    def test_queue_overflow_is_bounded_and_counted(self):
        runtime=Runtime({}); runtime.lua.globals().Config.batch.maxQueue=2
        for name in ['one','two','three']: runtime.event(name)
        self.assertEqual(runtime.t.queue.Size(runtime.t.queue),2)
        self.assertEqual(runtime.t.totals.dropped,1)
    def test_shutdown_checkpoints_unsent_events(self):
        disk={}; runtime=Runtime(disk); runtime.event(); runtime.lua.execute('t:Stop()')
        restored=Runtime(disk); self.assertEqual(restored.t.recovered,1)

    def test_fractional_receipt_does_not_discard_the_batch(self):
        runtime=Runtime({}); runtime.event(); runtime.flush()
        runtime.requests[0][1](202,'{"accepted":0.5,"duplicates":0.5,"rejected":0}')
        self.assertIsNotNone(runtime.t.inFlight)
        self.assertEqual(runtime.t.totals.sent,0)
    def test_malformed_snapshot_preserved_and_sending_blocked(self):
        snapshots = [
            {'v':1,'queued':[{'payload':{},'bytes':'bad'}]},
            {'v':1,'queued':[],'flight':{'body':'{}','count':1}},
            {'v':1,'queued':[],'dropped':-1},
        ]
        for snapshot in snapshots:
            with self.subTest(snapshot=snapshot):
                original=json.dumps(snapshot); disk={'data':original}; runtime=Runtime(disk)
                runtime.event(); runtime.flush()
                self.assertTrue(runtime.t.storageBlocked)
                self.assertEqual(runtime.requests,[])
                self.assertEqual(disk['data'],original)
    def test_restored_queue_obeys_reduced_limit_and_reports_drops(self):
        disk={}; runtime=Runtime(disk)
        for name in ['one','two','three']: runtime.event(name)
        runtime.lua.execute('t:Checkpoint()')
        restored=Runtime(disk,max_queue=2)
        self.assertEqual(restored.t.queue.Size(restored.t.queue),2)
        self.assertEqual(restored.t.totals.dropped,1)
        restored.flush()
        body=json.loads(restored.requests[0][0])
        self.assertEqual([event['id'] for event in body['events']],['two','three'])
        self.assertEqual(body['droppedSinceLast'],1)

class PublicApiTests(unittest.TestCase):
    def api(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute("""
            Config = { debug = false }
            registeredExports = {}
            function exports(name, fn) registeredExports[name] = fn end
            function GetCurrentResourceName() return 'vanish_logger' end
            function GetInvokingResource() return nil end
            function GetResourceMetadata() return '1.0.3' end
            function AddEventHandler(...) end
            function GetPlayerName(...) return nil end
            function NewId() return 'generated-id' end
            function UtcNow() return '2026-09-06T00:00:00Z' end
            function Debug(...) end
        """)
        lua.execute((ROOT/'server/limits.lua').read_text())
        lua.execute(ordinary_lua((ROOT/'server/util.lua').read_text()))
        lua.execute((ROOT/'server/api.lua').read_text())
        lua.execute('SetTransport({Enqueue=function(_, payload) lastPayload=payload; return true end})')
        return lua

    def test_malformed_containers_are_rejected_by_every_logging_export(self):
        for field in ('context', 'data'):
            for value in ('invalid', 42, False):
                for name in ('Log', 'LogTo', 'LogInventory'):
                    with self.subTest(field=field, value=value, export=name):
                        lua = self.api()
                        event = lua.table_from({'category': 'inventory', 'action': 'test', field: value})
                        fn = lua.globals().registeredExports[name]
                        args = (event,) if name == 'Log' else ('test', event)
                        if name == 'LogTo': args = ('custom.events', 'test', event)
                        self.assertFalse(fn(*args))
                        self.assertIsNone(lua.globals().lastPayload)

    def test_export_wrappers_reject_non_table_events(self):
        lua = self.api()
        for value in ('invalid', 42, False):
            self.assertFalse(lua.globals().registeredExports.Log(value))
            self.assertFalse(lua.globals().registeredExports.LogTo('custom.events', 'test', value))
            self.assertFalse(lua.globals().registeredExports.LogInventory('test', value))

    def test_valid_wrappers_and_context_still_work(self):
        lua = self.api()
        event = lua.table_from({'context': {'custom': 'kept'}, 'data': {'quantity': 1}}, recursive=True)
        self.assertTrue(lua.globals().registeredExports.LogTo('custom.events', 'test', event))
        self.assertEqual(lua.globals().lastPayload.context.custom, 'kept')
        self.assertEqual(lua.globals().lastPayload.context.resource, 'vanish_logger')
        self.assertIsNone(event.context.resource)
        self.assertEqual(lua.globals().lastPayload.data.quantity, 1)
        self.assertTrue(lua.globals().registeredExports.LogInventory('test', None))
        self.assertTrue(lua.globals().registeredExports.LogTo('custom.events', 'test', None))

    def test_invalid_destinations_and_actions_are_rejected(self):
        lua = self.api()
        for value in ('', 42, False):
            self.assertFalse(lua.globals().registeredExports.LogTo(value, 'test', None))
            self.assertFalse(lua.globals().registeredExports.LogInventory(value, None))
        self.assertFalse(lua.globals().LogEvent(lua.table_from({'category': 'inventory', 'action': 'test', 'channel': False})))

    def test_every_platform_category_is_accepted(self):
        # A category with no shipped collector is still a category a server's
        # own scripts may log to; refusing it here is what used to silently
        # swallow those events.
        lua = self.api()
        for category in ['inventory', 'money', 'player', 'vehicle',
                         'property', 'staff', 'security', 'system']:
            with self.subTest(category=category):
                self.assertTrue(lua.globals().LogEvent(
                    lua.table_from({'category': category, 'action': 'test'})))

    def test_unknown_category_is_refused_without_a_round_trip(self):
        lua = self.api()
        self.assertFalse(lua.globals().LogEvent(
            lua.table_from({'category': 'not_a_category', 'action': 'test'})))

    def test_action_and_a_destination_are_both_required(self):
        lua = self.api()
        self.assertFalse(lua.globals().LogEvent(lua.table_from({'category': 'system'})))
        self.assertFalse(lua.globals().LogEvent(lua.table_from({'action': 'orphan'})))

    def test_a_dashboard_channel_needs_no_category(self):
        lua = self.api()
        self.assertTrue(lua.globals().LogEvent(
            lua.table_from({'channel': 'drugs.sales', 'action': 'sold'})))
        self.assertEqual(lua.globals().lastPayload['channel'], 'drugs.sales')
        self.assertIsNone(lua.globals().lastPayload['category'])

if __name__ == '__main__': unittest.main()
